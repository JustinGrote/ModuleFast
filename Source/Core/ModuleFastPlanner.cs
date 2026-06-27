using System.Net;
using System.Text.Json;

using NuGet.Versioning;

namespace ModuleFast;

public class ModuleFastPlanner
{
  private readonly HttpClient _httpClient;
  private readonly string _source;

  public ModuleFastPlanner(HttpClient httpClient, string source)
  {
    _httpClient = httpClient;
    _source = source;
  }

  public async Task<HashSet<ModuleFastInfo>> GetPlanAsync(
      IEnumerable<ModuleFastSpec> specs,
      string[] modulePaths,
      bool update,
      bool prerelease,
      bool strictSemVer,
      bool destinationOnly,
      CancellationToken ct,
      ModuleFastMessageBuffer? messages = null)
  {
    var modulesToInstall = new HashSet<ModuleFastInfo>();
    var bestLocalCandidates = new Dictionary<ModuleFastSpec, ModuleFastInfo>();
    var pendingTasks = new Dictionary<Task<string>, ModuleFastSpec>();

    foreach (var spec in specs)
    {
      messages?.Verbose($"{spec}: Evaluating Module Specification");
      var localMatch = LocalModuleFinder.FindLocalModule(spec, modulePaths, update, bestLocalCandidates, strictSemVer, null, messages);
      if (localMatch != null && !update)
      {
        messages?.Debug($"{localMatch}: 🎯 FOUND satisfying version {localMatch.ModuleVersion} at {localMatch.Location}. Skipping remote search.");
        continue;
      }

      messages?.Debug($"{spec}: 🔍 No installed versions matched. Will check remotely.");
      var task = GetModuleInfoAsync(spec.Name, _source, ct);
      pendingTasks[task] = spec;
    }

    while (pendingTasks.Count > 0)
    {
      var snapshot = pendingTasks.Keys.ToArray();

      await foreach (var completed in Task.WhenEach(snapshot).WithCancellation(ct).ConfigureAwait(false))
      {
        if (!pendingTasks.TryGetValue(completed, out var currentSpec))
          continue;

        pendingTasks.Remove(completed);

        if (currentSpec.Guid != Guid.Empty)
          messages?.Warning($"{currentSpec}: A GUID constraint was found. GUIDs will only be verified after installation.");

        messages?.Debug($"{currentSpec}: Processing Response");

        string json;
        try
        {
          json = await completed.ConfigureAwait(false);
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
          throw new InvalidOperationException($"{currentSpec}: module was not found in the {_source} repository. Check the spelling and try again.");
        }
        catch (HttpRequestException ex)
        {
          throw new InvalidOperationException($"{currentSpec}: Failed to fetch module from {_source}. Error: {ex.Message}", ex);
        }

        RegistrationResponse response;
        try
        {
          response = JsonSerializer.Deserialize(json, ModuleFastJsonContext.Default.RegistrationResponse)
              ?? throw new InvalidDataException($"{currentSpec}: Invalid response from {_source}");
        }
        catch (JsonException ex)
        {
          throw new InvalidDataException($"{currentSpec}: Invalid JSON response from {_source}: {ex.Message}", ex);
        }

        if (response.Count == 0 && response.Items.Length == 0)
          throw new InvalidDataException($"{currentSpec}: invalid result received from {_source}.");

        var selectedEntry = FindBestEntry(response, currentSpec, prerelease, strictSemVer, messages);
        if (selectedEntry == null)
        {
          selectedEntry = await FetchBestEntryFromPagesAsync(response, currentSpec, prerelease, strictSemVer, ct, messages)
              .ConfigureAwait(false);
        }

        if (selectedEntry == null)
          throw new InvalidOperationException($"{currentSpec}: a matching module was not found in the {_source} repository that satisfies the version constraints. You may need to specify -PreRelease or adjust your version constraints.");

        if (string.IsNullOrEmpty(selectedEntry.PackageContent))
          throw new InvalidDataException($"No package location found for {currentSpec}. This is a bug.");

        if (selectedEntry.Tags != null && Array.Exists(selectedEntry.Tags, t => t == "ItemType:Script"))
          throw new NotImplementedException($"{currentSpec}: Script installations are currently not supported.");

        var selectedModule = new ModuleFastInfo(
            selectedEntry.Id,
            NuGetVersion.Parse(selectedEntry.Version),
            new Uri(selectedEntry.PackageContent));

        if (currentSpec.Guid != Guid.Empty)
          selectedModule.Guid = currentSpec.Guid;

        if (update && bestLocalCandidates.TryGetValue(currentSpec, out var bestLocal) &&
            bestLocal.ModuleVersion == selectedModule.ModuleVersion)
        {
          messages?.Debug($"{selectedModule}: -Update specified and best remote candidate matches what is locally installed. Skipping install.");
          continue;
        }

        if (!modulesToInstall.Add(selectedModule))
        {
          messages?.Debug($"{selectedModule} already exists in the install plan. Skipping...");
          continue;
        }

        messages?.Verbose($"{selectedModule}: Added to install plan");

        var allDeps = selectedEntry.DependencyGroups?
            .SelectMany(g => g.Dependencies ?? []) ?? [];

        foreach (var dep in allDeps)
        {
          var depRange = string.IsNullOrWhiteSpace(dep.Range)
              ? VersionRange.All
              : VersionRange.Parse(dep.Range);
          var depSpec = new ModuleFastSpec(dep.Id, depRange);

          var existing = modulesToInstall
              .Where(m => string.Equals(m.Name, depSpec.Name, StringComparison.OrdinalIgnoreCase))
              .OrderByDescending(m => m.ModuleVersion)
              .FirstOrDefault();
          if (existing != null && depSpec.SatisfiedBy(existing.ModuleVersion, strictSemVer))
          {
            messages?.Debug($"Dependency {depSpec} satisfied by existing planned install {existing}");
            continue;
          }

          var depLocal = LocalModuleFinder.FindLocalModule(depSpec, modulePaths, update, bestLocalCandidates, strictSemVer, null, messages);
          if (depLocal != null)
          {
            messages?.Debug($"FOUND local module {depLocal.Name} {depLocal.ModuleVersion} satisfies {depSpec}. Skipping...");
            continue;
          }

          messages?.Debug($"{currentSpec}: Fetching dependency {depSpec}");
          var depTask = GetModuleInfoAsync(depSpec.Name, _source, ct);
          pendingTasks[depTask] = depSpec;
        }
      }
    }

    return modulesToInstall;
  }

  private CatalogEntry? FindBestEntry(
      RegistrationResponse response,
      ModuleFastSpec spec,
      bool prerelease,
      bool strictSemVer,
      ModuleFastMessageBuffer? messages)
  {
    var inlinedLeaves = response.Items
        .Where(p => p.Items != null)
        .SelectMany(p => p.Items!)
        .ToArray();

    if (inlinedLeaves.Length == 0) return null;

    foreach (var leaf in inlinedLeaves)
    {
      if (!string.IsNullOrEmpty(leaf.PackageContent) && string.IsNullOrEmpty(leaf.CatalogEntry.PackageContent))
        leaf.CatalogEntry.PackageContent = leaf.PackageContent;
    }

    var entries = inlinedLeaves.Select(l => l.CatalogEntry).ToArray();
    if (entries.Length == 0) return null;

    var versions = new SortedSet<NuGetVersion>(
        entries.Select(e => NuGetVersion.TryParse(e.Version, out var v) ? v : null).Where(v => v != null)!);

    foreach (var candidate in versions.Reverse())
    {
      if ((candidate.IsPrerelease || candidate.HasMetadata) && !(spec.PreRelease || prerelease))
      {
        messages?.Debug($"{spec}: skipping candidate {candidate} - prerelease not requested.");
        continue;
      }

      if (spec.SatisfiedBy(candidate, strictSemVer))
      {
        messages?.Debug($"{spec}: Found satisfying version {candidate} in inlined index.");
        return entries.First(e => e.Version == candidate.OriginalVersion ||
            NuGetVersion.TryParse(e.Version, out var v) && v == candidate);
      }
    }

    return null;
  }

  private async Task<CatalogEntry?> FetchBestEntryFromPagesAsync(
      RegistrationResponse response,
      ModuleFastSpec spec,
      bool prerelease,
      bool strictSemVer,
      CancellationToken ct,
      ModuleFastMessageBuffer? messages)
  {
    messages?.Debug($"{spec}: not found in inlined index. Determining appropriate page(s) to query.");

    var pages = response.Items
        .Where(p => p.Items == null)
        .Where(p =>
        {
          if (string.IsNullOrEmpty(p.Lower) || string.IsNullOrEmpty(p.Upper)) return true;
          if (!NuGetVersion.TryParse(p.Lower, out var lower) || !NuGetVersion.TryParse(p.Upper, out var upper)) return true;
          var pageRange = new VersionRange(lower, true, upper, true);
          return spec.Overlap(pageRange);
        })
        .OrderByDescending(p => NuGetVersion.TryParse(p.Upper, out var v) ? v : null)
        .ToArray();

    if (pages.Length == 0)
      throw new InvalidOperationException($"{spec}: a matching module was not found in the {_source} repository that satisfies the requested version constraints. You may need to specify -PreRelease or adjust your version constraints.");

    messages?.Debug($"{spec}: Found {pages.Length} additional pages to query.");

    var pageJsonTasks = pages.Select(p => GetCachedStringAsync(p.Id, ct)).ToArray();
    var pageJsons = await Task.WhenAll(pageJsonTasks).ConfigureAwait(false);

    for (int i = 0; i < pages.Length; i++)
    {
      RegistrationPage pageData;
      try
      {
        pageData = JsonSerializer.Deserialize(pageJsons[i], ModuleFastJsonContext.Default.RegistrationPage)
            ?? throw new InvalidDataException("Invalid page response");
      }
      catch (JsonException)
      {
        var pageResponse = JsonSerializer.Deserialize(pageJsons[i], ModuleFastJsonContext.Default.RegistrationResponse);
        pageData = pageResponse?.Items?.FirstOrDefault() ?? new RegistrationPage();
      }

      if (pageData.Items == null) continue;

      foreach (var leaf in pageData.Items)
      {
        if (!string.IsNullOrEmpty(leaf.PackageContent) && string.IsNullOrEmpty(leaf.CatalogEntry.PackageContent))
          leaf.CatalogEntry.PackageContent = leaf.PackageContent;
      }

      var entries = pageData.Items.Select(l => l.CatalogEntry).ToArray();
      var versions = new SortedSet<NuGetVersion>(
          entries.Select(e => NuGetVersion.TryParse(e.Version, out var v) ? v : null).Where(v => v != null)!);

      foreach (var candidate in versions.Reverse())
      {
        if ((candidate.IsPrerelease || candidate.HasMetadata) && !(spec.PreRelease || prerelease))
          continue;

        if (spec.SatisfiedBy(candidate, strictSemVer))
        {
          messages?.Debug($"{spec}: Found satisfying version {candidate} in additional pages.");
          return entries.First(e => NuGetVersion.TryParse(e.Version, out var v) && v == candidate);
        }
      }
    }

    return null;
  }

  private async Task<string> GetModuleInfoAsync(string name, string endpoint, CancellationToken ct)
  {
    var registrationBase = await GetRegistrationBaseAsync(endpoint, ct).ConfigureAwait(false);
    var uri = $"{registrationBase.TrimEnd('/')}/{name.ToLowerInvariant()}/index.json";
    return await GetCachedStringAsync(uri, ct).ConfigureAwait(false);
  }

  private async Task<string> GetRegistrationBaseAsync(string endpoint, CancellationToken ct)
  {
    var indexJson = await GetCachedStringAsync(endpoint, ct).ConfigureAwait(false);
    var index = JsonSerializer.Deserialize(indexJson, ModuleFastJsonContext.Default.RegistrationIndex)
        ?? throw new InvalidDataException("Invalid registration index from " + endpoint);

    var registrationBase = index.Resources
        .Where(r => r.Type.Contains("RegistrationsBaseUrl"))
        .OrderByDescending(r => r.Type)
        .Select(r => r.Id)
        .FirstOrDefault()
        ?? throw new InvalidDataException($"Could not find RegistrationsBaseUrl in index from {endpoint}");

    return registrationBase;
  }

  private async Task<string> GetCachedStringAsync(string url, CancellationToken ct)
  {
    return await ModuleFastCache.Instance.GetOrAdd(url, async _ =>
        await _httpClient.GetStringAsync(url, ct).ConfigureAwait(false)).ConfigureAwait(false);
  }
}
