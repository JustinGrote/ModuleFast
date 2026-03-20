using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using NuGet.Versioning;

namespace ModuleFast;

public class ModuleFastPlanner
{
    private readonly HttpClient _httpClient;
    private readonly string _source;
    private static readonly JsonSerializerOptions _jsonOpts = new() { PropertyNameCaseInsensitive = true };

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
        PSCmdlet? cmdlet = null)
    {
        var modulesToInstall = new HashSet<ModuleFastInfo>();
        var bestLocalCandidates = new Dictionary<ModuleFastSpec, ModuleFastInfo>();
        var pendingTasks = new Dictionary<Task<string>, ModuleFastSpec>();

        // Seed initial tasks
        foreach (var spec in specs)
        {
            cmdlet?.WriteVerbose($"{spec}: Evaluating Module Specification");
            var localMatch = LocalModuleFinder.FindLocalModule(spec, modulePaths, update, bestLocalCandidates, strictSemVer, cmdlet);
            if (localMatch != null && !update)
            {
                cmdlet?.WriteDebug($"{localMatch}: 🎯 FOUND satisfying version {localMatch.ModuleVersion} at {localMatch.Location}. Skipping remote search.");
                continue;
            }
            cmdlet?.WriteDebug($"{spec}: 🔍 No installed versions matched. Will check remotely.");
            var task = GetModuleInfoAsync(spec.Name, _source, ct);
            pendingTasks[task] = spec;
        }

        while (pendingTasks.Count > 0)
        {
            var completed = await Task.WhenAny(pendingTasks.Keys).ConfigureAwait(false);
            var currentSpec = pendingTasks[completed];
            pendingTasks.Remove(completed);

            if (currentSpec.Guid != Guid.Empty)
                cmdlet?.WriteWarning($"{currentSpec}: A GUID constraint was found. GUIDs will only be verified after installation.");

            cmdlet?.WriteDebug($"{currentSpec}: Processing Response");

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
                response = JsonSerializer.Deserialize<RegistrationResponse>(json, _jsonOpts)
                    ?? throw new InvalidDataException($"{currentSpec}: Invalid response from {_source}");
            }
            catch (JsonException ex)
            {
                throw new InvalidDataException($"{currentSpec}: Invalid JSON response from {_source}: {ex.Message}", ex);
            }

            if (response.Count == 0 && response.Items.Length == 0)
                throw new InvalidDataException($"{currentSpec}: invalid result received from {_source}.");

            var selectedEntry = FindBestEntry(response, currentSpec, prerelease, strictSemVer, cmdlet);
            if (selectedEntry == null)
            {
                // Try non-inlined pages
                selectedEntry = await FetchBestEntryFromPagesAsync(response, currentSpec, prerelease, strictSemVer, ct, cmdlet)
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

            // If -Update was specified, check if best local candidate matches
            if (update && bestLocalCandidates.TryGetValue(currentSpec, out var bestLocal) &&
                bestLocal.ModuleVersion == selectedModule.ModuleVersion)
            {
                cmdlet?.WriteDebug($"{selectedModule}: ✅ -Update specified and best remote matches local. Skipping.");
                continue;
            }

            if (!modulesToInstall.Add(selectedModule))
            {
                cmdlet?.WriteDebug($"{selectedModule} already exists in the install plan. Skipping...");
                continue;
            }

            cmdlet?.WriteVerbose($"{selectedModule}: Added to install plan");

            // Queue dependency tasks
            var allDeps = selectedEntry.DependencyGroups?
                .SelectMany(g => g.Dependencies ?? []) ?? [];

            foreach (var dep in allDeps)
            {
                var depRange = string.IsNullOrWhiteSpace(dep.Range)
                    ? VersionRange.All
                    : VersionRange.Parse(dep.Range);
                var depSpec = new ModuleFastSpec(dep.Id, depRange);

                // Check if already satisfied by planned installs
                var moduleNames = new HashSet<string>(modulesToInstall.Select(m => m.Name), StringComparer.OrdinalIgnoreCase);
                if (moduleNames.Contains(depSpec.Name))
                {
                    var existing = modulesToInstall.Where(m => string.Equals(m.Name, depSpec.Name, StringComparison.OrdinalIgnoreCase))
                        .OrderByDescending(m => m.ModuleVersion)
                        .FirstOrDefault();
                    if (existing != null && depSpec.SatisfiedBy(existing.ModuleVersion, strictSemVer))
                    {
                        cmdlet?.WriteDebug($"Dependency {depSpec} satisfied by existing planned install {existing}");
                        continue;
                    }
                }

                var depLocal = LocalModuleFinder.FindLocalModule(depSpec, modulePaths, update, bestLocalCandidates, strictSemVer, cmdlet);
                if (depLocal != null)
                {
                    cmdlet?.WriteDebug($"FOUND local module {depLocal.Name} {depLocal.ModuleVersion} satisfies {depSpec}. Skipping...");
                    continue;
                }

                cmdlet?.WriteDebug($"{currentSpec}: Fetching dependency {depSpec}");
                var depTask = GetModuleInfoAsync(depSpec.Name, _source, ct);
                pendingTasks[depTask] = depSpec;
            }
        }

        return modulesToInstall;
    }

    private CatalogEntry? FindBestEntry(
        RegistrationResponse response,
        ModuleFastSpec spec,
        bool prerelease,
        bool strictSemVer,
        PSCmdlet? cmdlet)
    {
        var inlinedLeaves = response.Items
            .Where(p => p.Items != null)
            .SelectMany(p => p.Items!)
            .ToArray();

        if (inlinedLeaves.Length == 0) return null;

        // Normalize packageContent
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
                cmdlet?.WriteDebug($"{spec}: skipping candidate {candidate} - prerelease not requested.");
                continue;
            }
            if (spec.SatisfiedBy(candidate, strictSemVer))
            {
                cmdlet?.WriteDebug($"{spec}: Found satisfying version {candidate} in inlined index.");
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
        PSCmdlet? cmdlet)
    {
        cmdlet?.WriteDebug($"{spec}: not found in inlined index. Determining appropriate page(s) to query.");

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

        cmdlet?.WriteDebug($"{spec}: Found {pages.Length} additional pages to query.");

        foreach (var page in pages)
        {
            var pageJson = await GetCachedStringAsync(page.Id, ct).ConfigureAwait(false);
            RegistrationPage pageData;
            try
            {
                pageData = JsonSerializer.Deserialize<RegistrationPage>(pageJson, _jsonOpts)
                    ?? throw new InvalidDataException("Invalid page response");
            }
            catch (JsonException)
            {
                // Some servers return RegistrationResponse for page URLs too
                var pageResponse = JsonSerializer.Deserialize<RegistrationResponse>(pageJson, _jsonOpts);
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
                    cmdlet?.WriteDebug($"{spec}: Found satisfying version {candidate} in additional pages.");
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
        var index = JsonSerializer.Deserialize<RegistrationIndex>(indexJson, _jsonOpts)
            ?? throw new InvalidDataException("Invalid registration index from " + endpoint);

        var registrationBase = index.Resources
            .Where(r => r.Type.Contains("RegistrationsBaseUrl"))
            .OrderByDescending(r => r.Type)
            .Select(r => r.Id)
            .FirstOrDefault()
            ?? throw new InvalidDataException($"Could not find RegistrationsBaseUrl in index from {endpoint}");

        return registrationBase;
    }

    private Task<string> GetCachedStringAsync(string uri, CancellationToken ct)
    {
        var cached = ModuleFastCache.Instance.Get(uri);
        if (cached != null)
            return cached;

        var task = _httpClient.GetStringAsync(uri, ct);
        ModuleFastCache.Instance.Set(uri, task);
        return task;
    }
}
