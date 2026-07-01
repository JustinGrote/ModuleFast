using System.Collections.Concurrent;
using System.Net;

using NuGet.Common;
using NuGet.Configuration;
using NuGet.Protocol;
using NuGet.Protocol.Core.Types;

using NuGet.Versioning;

namespace ModuleFast;

public class ModuleFastPlanner(
  string source
)
{
  private readonly SourceRepository _sourceRepository = new(
      new PackageSource(source),
      Repository.Provider.GetCoreV3());

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
    PackageMetadataResource metadataResource = await _sourceRepository
      .GetResourceAsync<PackageMetadataResource>(ct)
      .ConfigureAwait(false);

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

        IEnumerable<IPackageSearchMetadata> allMetadata;
        try
        {
          using SourceCacheContext cacheContext = new();
          allMetadata = await metadataResource.GetMetadataAsync(
              currentSpec.Name,
              includePrerelease: true,
              includeUnlisted: false,
              cacheContext,
              NullLogger.Instance,
              token).ConfigureAwait(false);
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
          throw new InvalidOperationException($"{currentSpec}: module was not found in the {source} repository. Check the spelling and try again.");
        }
        catch (HttpRequestException ex)
        {
          throw new InvalidOperationException($"{currentSpec}: Failed to fetch module from {source}. Error: {ex.Message}", ex);
        }

        IPackageSearchMetadata? selectedPackage = allMetadata
            .Where(m => m.Identity != null)
            .OrderByDescending(m => m.Identity.Version)
            .FirstOrDefault(m =>
            {
              NuGetVersion candidate = m.Identity.Version;
              if ((candidate.IsPrerelease || candidate.HasMetadata) && !(currentSpec.PreRelease || prerelease))
              {
                cmdlet?.Debug($"{currentSpec}: skipping candidate {candidate} - prerelease not requested.");
                return false;
              }

              if (!currentSpec.SatisfiedBy(candidate, strictSemVer))
                return false;

              cmdlet?.Debug($"{currentSpec}: Found satisfying version {candidate}.");
              return true;
            });

        if (selectedPackage == null)
          throw new InvalidOperationException($"{currentSpec}: a matching module was not found in the {source} repository that satisfies the version constraints. You may need to specify -PreRelease or adjust your version constraints.");

        if (!string.IsNullOrEmpty(selectedPackage.Tags) &&
            selectedPackage.Tags.Contains("ItemType:Script", StringComparison.OrdinalIgnoreCase))
          throw new NotImplementedException($"{currentSpec}: Script installations are currently not supported.");

        ModuleFastInfo selectedModule = new ModuleFastInfo(
            selectedPackage.Identity.Id,
            selectedPackage.Identity.Version,
            new Uri(source));

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

        var allDeps = selectedPackage.DependencySets?
            .SelectMany(g => g.Packages ?? []) ?? [];

        foreach (var dep in allDeps)
        {
          VersionRange depRange = dep.VersionRange ?? VersionRange.All;
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
}
