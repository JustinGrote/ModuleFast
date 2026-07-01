using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;

using NuGet.Versioning;

namespace ModuleFast;

public class ModuleFastPlanner(
  HttpClient httpClient,
  string source
)
{
  public async Task<HashSet<ModuleFastInfo>> GetPlan(
      IEnumerable<ModuleFastSpec> specs,
      string[] modulePaths,
      bool update,
      bool prerelease,
      bool strictSemVer,
      bool destinationOnly,
      CancellationToken ct,
      CmdletInteraction? cmdlet = null)
  {
    ConcurrentDictionary<ModuleFastInfo, byte> modulesToInstall = [];
    ConcurrentDictionary<ModuleFastSpec, ModuleFastInfo> bestLocalCandidates = [];
    ConcurrentDictionary<ModuleFastSpec, byte> enqueuedSpecs = [];
    ConcurrentQueue<ModuleFastSpec> pendingSpecs = [];

    foreach (ModuleFastSpec spec in specs)
    {
      if (enqueuedSpecs.TryAdd(spec, 0))
        pendingSpecs.Enqueue(spec);
    }

    while (!pendingSpecs.IsEmpty)
    {
      List<ModuleFastSpec> batch = [];
      while (pendingSpecs.TryDequeue(out ModuleFastSpec? spec))
        batch.Add(spec);

      if (batch.Count == 0)
        continue;

      await Parallel.ForEachAsync(batch, ct, async (currentSpec, token) =>
      {
        cmdlet?.Verbose($"{currentSpec}: Evaluating Module Specification");

        ModuleFastInfo? localMatch = await LocalModuleFinder.FindLocalModule(
            currentSpec,
            modulePaths,
            update,
            bestLocalCandidates,
            strictSemVer,
            token,
            cmdlet).ConfigureAwait(false);
        if (localMatch != null && !update)
        {
          cmdlet?.Debug($"{localMatch}: 🎯 FOUND satisfying version {localMatch.ModuleVersion} at {localMatch.Location}. Skipping remote search.");
          return;
        }

        cmdlet?.Debug($"{currentSpec}: 🔍 No installed versions matched. Will check remotely.");

        if (currentSpec.Guid != Guid.Empty)
          cmdlet?.Warning($"{currentSpec}: A GUID constraint was found. GUIDs will only be verified after installation.");

        cmdlet?.Debug($"{currentSpec}: Processing Response");

        string json;
        try
        {
          json = await GetModuleInfoAsync(currentSpec.Name, source, token).ConfigureAwait(false);
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
          throw new InvalidOperationException($"{currentSpec}: module was not found in the {source} repository. Check the spelling and try again.");
        }
        catch (HttpRequestException ex)
        {
          throw new InvalidOperationException($"{currentSpec}: Failed to fetch module from {source}. Error: {ex.Message}", ex);
        }

        RegistrationResponse response;
        try
        {
          response = JsonSerializer.Deserialize(json, ModuleFastJsonContext.Default.RegistrationResponse)
              ?? throw new InvalidDataException($"{currentSpec}: Invalid response from {source}");
        }
        catch (JsonException ex)
        {
          throw new InvalidDataException($"{currentSpec}: Invalid JSON response from {source}: {ex.Message}", ex);
        }

        if (response.Count == 0 && response.Items.Length == 0)
          throw new InvalidDataException($"{currentSpec}: invalid result received from {source}.");

        CatalogEntry? selectedEntry = FindBestEntry(response, currentSpec, prerelease, strictSemVer, cmdlet);
        if (selectedEntry == null)
        {
          selectedEntry = await FetchBestEntryFromPagesAsync(response, currentSpec, prerelease, strictSemVer, token, cmdlet)
              .ConfigureAwait(false);
        }

        if (selectedEntry == null)
          throw new InvalidOperationException($"{currentSpec}: a matching module was not found in the {source} repository that satisfies the version constraints. You may need to specify -PreRelease or adjust your version constraints.");

        if (string.IsNullOrEmpty(selectedEntry.PackageContent))
          throw new InvalidDataException($"No package location found for {currentSpec}. This is a bug.");

        if (selectedEntry.Tags != null && Array.Exists(selectedEntry.Tags, t => t == "ItemType:Script"))
          throw new NotImplementedException($"{currentSpec}: Script installations are currently not supported.");

        ModuleFastInfo selectedModule = new ModuleFastInfo(
            selectedEntry.Id,
            NuGetVersion.Parse(selectedEntry.Version),
            new Uri(selectedEntry.PackageContent));

        if (currentSpec.Guid != Guid.Empty)
          selectedModule = selectedModule with { Guid = currentSpec.Guid };

        if (update && bestLocalCandidates.TryGetValue(currentSpec, out ModuleFastInfo? bestLocal) &&
            bestLocal.ModuleVersion == selectedModule.ModuleVersion)
        {
          cmdlet?.Debug($"{selectedModule}: -Update specified and best remote candidate matches what is locally installed. Skipping install.");
          return;
        }

        if (!modulesToInstall.TryAdd(selectedModule, 0))
        {
          cmdlet?.Debug($"{selectedModule} already exists in the install plan. Skipping...");
          return;
        }

        cmdlet?.Verbose($"{selectedModule}: Added to install plan");

        IEnumerable<Dependency> allDeps = selectedEntry.DependencyGroups?
            .SelectMany(g => g.Dependencies ?? []) ?? [];

        foreach (Dependency? dep in allDeps)
        {
          VersionRange depRange = string.IsNullOrWhiteSpace(dep.Range)
              ? VersionRange.All
              : VersionRange.Parse(dep.Range);
          ModuleFastSpec depSpec = new ModuleFastSpec(dep.Id, depRange);

          ModuleFastInfo? existing = modulesToInstall.Keys
              .Where(m => string.Equals(m.Name, depSpec.Name, StringComparison.OrdinalIgnoreCase))
              .OrderByDescending(m => m.ModuleVersion)
              .FirstOrDefault();
          if (existing != null && depSpec.SatisfiedBy(existing.ModuleVersion, strictSemVer))
          {
            cmdlet?.Debug($"Dependency {depSpec} satisfied by existing planned install {existing}");
            continue;
          }

          ModuleFastInfo? depLocal = await LocalModuleFinder.FindLocalModule(
              depSpec,
              modulePaths,
              update,
              bestLocalCandidates,
              strictSemVer,
              token,
              cmdlet).ConfigureAwait(false);
          if (depLocal != null)
          {
            cmdlet?.Debug($"FOUND local module {depLocal.Name} {depLocal.ModuleVersion} satisfies {depSpec}. Skipping...");
            continue;
          }

          cmdlet?.Debug($"{currentSpec}: Queueing dependency {depSpec}");
          if (enqueuedSpecs.TryAdd(depSpec, 0))
            pendingSpecs.Enqueue(depSpec);
        }
      }).ConfigureAwait(false);
    }

    return modulesToInstall.Keys.ToHashSet();
  }

  private CatalogEntry? FindBestEntry(
      RegistrationResponse response,
      ModuleFastSpec spec,
      bool prerelease,
      bool strictSemVer,
      CmdletInteraction? messages)
  {
    RegistrationLeaf[] inlinedLeaves = response.Items
        .Where(p => p.Items != null)
        .SelectMany(p => p.Items!)
        .ToArray();

    if (inlinedLeaves.Length == 0) return null;

    foreach (RegistrationLeaf? leaf in inlinedLeaves)
    {
      if (!string.IsNullOrEmpty(leaf.PackageContent) && string.IsNullOrEmpty(leaf.CatalogEntry.PackageContent))
        leaf.CatalogEntry.PackageContent = leaf.PackageContent;
    }

    CatalogEntry[] entries = inlinedLeaves.Select(l => l.CatalogEntry).ToArray();
    if (entries.Length == 0) return null;

    SortedSet<NuGetVersion> versions = new SortedSet<NuGetVersion>(
        entries.Select(e => NuGetVersion.TryParse(e.Version, out NuGetVersion? v) ? v : null).Where(v => v != null)!);

    foreach (NuGetVersion candidate in versions.Reverse())
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
            NuGetVersion.TryParse(e.Version, out NuGetVersion? v) && v == candidate);
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
      CmdletInteraction? messages)
  {
    messages?.Debug($"{spec}: not found in inlined index. Determining appropriate page(s) to query.");

    RegistrationPage[] pages = response.Items
        .Where(p => p.Items == null)
        .Where(p =>
        {
          if (string.IsNullOrEmpty(p.Lower) || string.IsNullOrEmpty(p.Upper)) return true;
          if (!NuGetVersion.TryParse(p.Lower, out NuGetVersion? lower) || !NuGetVersion.TryParse(p.Upper, out NuGetVersion? upper)) return true;
          VersionRange pageRange = new VersionRange(lower, true, upper, true);
          return spec.Overlap(pageRange);
        })
        .OrderByDescending(p => NuGetVersion.TryParse(p.Upper, out NuGetVersion? v) ? v : null)
        .ToArray();

    if (pages.Length == 0)
      throw new InvalidOperationException($"{spec}: a matching module was not found in the {source} repository that satisfies the requested version constraints. You may need to specify -PreRelease or adjust your version constraints.");

    messages?.Debug($"{spec}: Found {pages.Length} additional pages to query.");

    Task<string>[] pageJsonTasks = pages.Select(p => GetCachedStringAsync(p.Id, ct)).ToArray();
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
        RegistrationResponse? pageResponse = JsonSerializer.Deserialize(pageJsons[i], ModuleFastJsonContext.Default.RegistrationResponse);
        pageData = pageResponse?.Items?.FirstOrDefault() ?? new RegistrationPage();
      }

      if (pageData.Items == null) continue;

      foreach (RegistrationLeaf leaf in pageData.Items)
      {
        if (!string.IsNullOrEmpty(leaf.PackageContent) && string.IsNullOrEmpty(leaf.CatalogEntry.PackageContent))
          leaf.CatalogEntry.PackageContent = leaf.PackageContent;
      }

      CatalogEntry[] entries = pageData.Items.Select(l => l.CatalogEntry).ToArray();
      SortedSet<NuGetVersion> versions = new SortedSet<NuGetVersion>(
          entries.Select(e => NuGetVersion.TryParse(e.Version, out NuGetVersion? v) ? v : null).Where(v => v != null)!);

      foreach (NuGetVersion candidate in versions.Reverse())
      {
        if ((candidate.IsPrerelease || candidate.HasMetadata) && !(spec.PreRelease || prerelease))
          continue;

        if (spec.SatisfiedBy(candidate, strictSemVer))
        {
          messages?.Debug($"{spec}: Found satisfying version {candidate} in additional pages.");
          return entries.First(e => NuGetVersion.TryParse(e.Version, out NuGetVersion? v) && v == candidate);
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
    RegistrationIndex index = JsonSerializer.Deserialize(indexJson, ModuleFastJsonContext.Default.RegistrationIndex)
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
        await httpClient.GetStringAsync(url, ct).ConfigureAwait(false)).ConfigureAwait(false);
  }
}
