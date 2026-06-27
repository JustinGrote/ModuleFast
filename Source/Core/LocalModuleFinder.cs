using System.Management.Automation;
using System.Text.RegularExpressions;

using NuGet.Versioning;

namespace ModuleFast;

public static partial class LocalModuleFinder
{
  [GeneratedRegex(@"^\d+\.\d+\.\d+\.\d+$", RegexOptions.Compiled)]
  private static partial Regex FourPartVersionRegex();
  /// <summary>
  /// Resolves the folder version from a NuGetVersion: 4-part stays as-is, 3-part strips trailing .0.
  /// </summary>
  public static Version ResolveFolderVersion(NuGetVersion version)
  {
    if (version.IsLegacyVersion ||
        FourPartVersionRegex().IsMatch(version.OriginalVersion ?? ""))
      return version.Version;
    return new Version(version.Major, version.Minor, version.Patch);
  }

  /// <summary>
  /// Searches local PSModulePaths for the first module that satisfies the ModuleSpec criteria.
  /// Returns null if no match found.
  /// </summary>
  public static ModuleFastInfo? FindLocalModule(
      ModuleFastSpec spec,
      string[]? modulePaths,
      bool update,
      Dictionary<ModuleFastSpec, ModuleFastInfo>? bestCandidates,
      bool strictSemVer,
      PSCmdlet? cmdlet = null,
      ModuleFastMessageBuffer? messages = null)
  {
    if (modulePaths == null || modulePaths.Length == 0)
    {
      messages?.Warning("No PSModulePaths found. If you are doing isolated testing you can disregard this.");
      cmdlet?.WriteWarning("No PSModulePaths found. If you are doing isolated testing you can disregard this.");
      return null;
    }

    foreach (var modulePath in modulePaths)
    {
      if (!Directory.Exists(modulePath))
      {
        messages?.Debug($"{spec}: Skipping PSModulePath {modulePath} - Configured but does not exist.");
        cmdlet?.WriteDebug($"{spec}: Skipping PSModulePath {modulePath} - Configured but does not exist.");
        continue;
      }

      // Case-insensitive search for module base dir
      var moduleDirs = Directory.EnumerateDirectories(modulePath, spec.Name,
          new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive }).ToArray();

      if (moduleDirs.Length > 1)
        throw new InvalidOperationException($"{spec.Name} folder is ambiguous, please delete one: {string.Join(", ", moduleDirs)}");
      if (moduleDirs.Length == 0)
      {
        messages?.Debug($"{spec}: Skipping PSModulePath {modulePath} - Does not have this module.");
        cmdlet?.WriteDebug($"{spec}: Skipping PSModulePath {modulePath} - Does not have this module.");
        continue;
      }

      var moduleBaseDir = moduleDirs[0];
      var candidatePaths = new List<(Version version, string path)>();
      var manifestName = $"{spec.Name}.psd1";

      var required = spec.Required;
      if (required != null)
      {
        var moduleVersion = ResolveFolderVersion(required);
        var moduleFolder = Path.Combine(moduleBaseDir, moduleVersion.ToString());
        if (Directory.Exists(moduleFolder))
          candidatePaths.Add((moduleVersion, moduleFolder));
      }
      else
      {
        // Enumerate versioned sub-folders
        foreach (var folder in Directory.EnumerateDirectories(moduleBaseDir))
        {
          var leafName = Path.GetFileName(folder);
          if (!Version.TryParse(leafName, out var version))
          {
            messages?.Debug($"Could not parse {folder} in {moduleBaseDir} as a valid version.");
            cmdlet?.WriteDebug($"Could not parse {folder} in {moduleBaseDir} as a valid version.");
            continue;
          }

          if (spec.Max != null && version > spec.Max.Version)
          {
            messages?.Debug($"{spec}: Skipping {folder} - above the upper bound");
            cmdlet?.WriteDebug($"{spec}: Skipping {folder} - above the upper bound");
            continue;
          }

          if (spec.Min != null)
          {
            var originalParts = (spec.Min.OriginalVersion ?? "").Split('-')[0];
            var minVersion = Version.TryParse(originalParts, out var parsedBase) && parsedBase.Revision == -1
                ? parsedBase
                : spec.Min.Version;
            if (version < minVersion)
            {
              messages?.Debug($"{spec}: Skipping {folder} - {version} is below the lower bound of {minVersion}");
              cmdlet?.WriteDebug($"{spec}: Skipping {folder} - {version} is below the lower bound of {minVersion}");
              continue;
            }
          }

          candidatePaths.Add((version, folder));
        }

        // Sort descending by version
        candidatePaths.Sort((a, b) => b.version.CompareTo(a.version));
      }

      // Classic module fallback
      if (candidatePaths.Count == 0)
      {
        var classicManifests = Directory.GetFiles(moduleBaseDir, manifestName,
            new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive });
        if (classicManifests.Length > 1)
          throw new InvalidOperationException($"{moduleBaseDir} manifest is ambiguous: {string.Join(", ", classicManifests)}");
        if (classicManifests.Length == 1)
        {
          var classicManifestPath = classicManifests[0];
          var classicData = messages != null
              ? ModuleManifestReader.ImportModuleManifest(classicManifestPath, messages)
              : ModuleManifestReader.ImportModuleManifest(classicManifestPath, cmdlet);
          if (Version.TryParse(classicData["ModuleVersion"]?.ToString() ?? "", out var classicVersion))
          {
            messages?.Debug($"{spec}: Found classic module {classicVersion} at {moduleBaseDir}");
            cmdlet?.WriteDebug($"{spec}: Found classic module {classicVersion} at {moduleBaseDir}");
            candidatePaths.Add((classicVersion, moduleBaseDir));
          }
        }
      }

      if (candidatePaths.Count == 0)
      {
        messages?.Debug($"{spec}: Skipping PSModulePath {modulePath} - No installed versions matched the spec.");
        cmdlet?.WriteDebug($"{spec}: Skipping PSModulePath {modulePath} - No installed versions matched the spec.");
        continue;
      }

      foreach (var (version, folder) in candidatePaths)
      {
        if (File.Exists(Path.Combine(folder, ".incomplete")))
        {
          messages?.Warning($"{spec}: Incomplete installation detected at {folder}. Deleting and ignoring.");
          cmdlet?.WriteWarning($"{spec}: Incomplete installation detected at {folder}. Deleting and ignoring.");
          try
          {
            Directory.Delete(folder, true);
          }
          catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
          {
            messages?.Warning($"{spec}: Failed to delete incomplete installation at {folder}: {ex.Message}");
            cmdlet?.WriteWarning($"{spec}: Failed to delete incomplete installation at {folder}: {ex.Message}");
          }
          continue;
        }

        var manifests = Directory.GetFiles(folder, manifestName,
            new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive });

        if (manifests.Length > 1)
          throw new InvalidOperationException($"{folder} manifest is ambiguous: {string.Join(", ", manifests)}");
        if (manifests.Length == 0)
        {
          messages?.Warning($"{spec}: Found candidate folder {folder} but no {manifestName} manifest found. This may be a corrupt module.");
          cmdlet?.WriteWarning($"{spec}: Found candidate folder {folder} but no {manifestName} manifest found. This may be a corrupt module.");
          continue;
        }

        ModuleFastInfo manifestCandidate;
        try
        {
          manifestCandidate = messages != null
              ? ModuleManifestReader.ConvertFromModuleManifest(manifests[0], messages)
              : ModuleManifestReader.ConvertFromModuleManifest(manifests[0], cmdlet);
        }
        catch (Exception ex)
        {
          messages?.Warning($"{spec}: Failed to read manifest at {manifests[0]}: {ex.Message}");
          cmdlet?.WriteWarning($"{spec}: Failed to read manifest at {manifests[0]}: {ex.Message}");
          continue;
        }

        if (spec.Guid != Guid.Empty && manifestCandidate.Guid != spec.Guid)
        {
          messages?.Warning($"{spec}: Module at {folder} GUID {manifestCandidate.Guid} does not match spec GUID {spec.Guid}.");
          cmdlet?.WriteWarning($"{spec}: Module at {folder} GUID {manifestCandidate.Guid} does not match spec GUID {spec.Guid}.");
          continue;
        }

        var candidateVersion = manifestCandidate.ModuleVersion;

        if (spec.SatisfiedBy(candidateVersion, strictSemVer))
        {
          if (update && spec.Max != candidateVersion)
          {
            messages?.Debug($"{spec}: Skipping {candidateVersion} because -Update was specified and version does not exactly meet upper bound.");
            cmdlet?.WriteDebug($"{spec}: Skipping {candidateVersion} because -Update was specified and version does not exactly meet upper bound.");
            if (bestCandidates != null &&
                (!bestCandidates.TryGetValue(spec, out var existing) ||
                 manifestCandidate.ModuleVersion > existing.ModuleVersion))
            {
              messages?.Debug($"{spec}: ⬆️ New Best Candidate Version {manifestCandidate.ModuleVersion}");
              cmdlet?.WriteDebug($"{spec}: ⬆️ New Best Candidate Version {manifestCandidate.ModuleVersion}");
              bestCandidates[spec] = manifestCandidate;
            }
            continue;
          }
          return manifestCandidate;
        }
      }
    }

    return null;
  }
}