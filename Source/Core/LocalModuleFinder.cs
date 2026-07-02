using System.Management.Automation;
using System.Text.RegularExpressions;

using NuGet.Versioning;

namespace ModuleFast;

public static partial class LocalModuleFinder
{
  [GeneratedRegex(@"^\d+\.\d+\.\d+\.\d+$", RegexOptions.Compiled)]
  private static partial Regex FourPartVersionRegex();

  private static string? FindSinglePathOrThrow(IEnumerable<string> matches, string ambiguityPrefix)
  {
    using IEnumerator<string> enumerator = matches.GetEnumerator();
    if (!enumerator.MoveNext())
      return null;

    string first = enumerator.Current;
    if (!enumerator.MoveNext())
      return first;

    List<string> allMatches = [first, enumerator.Current];
    while (enumerator.MoveNext())
      allMatches.Add(enumerator.Current);

    throw new InvalidOperationException($"{ambiguityPrefix}: {string.Join(", ", allMatches)}");
  }

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
  public static async Task<ModuleFastInfo?> FindLocalModule(
      ModuleFastSpec spec,
      string[]? modulePaths,
      bool update,
      IDictionary<ModuleFastSpec, ModuleFastInfo>? bestCandidates,
      bool strictSemVer,
      CancellationToken ct = default,
      CmdletInteraction? logger = null)
  {
    if (modulePaths == null || modulePaths.Length == 0)
    {
      logger?.Warning("No PSModulePaths found. If you are doing isolated testing you can disregard this.");
      return null;
    }

    foreach (var modulePath in modulePaths)
    {
      ct.ThrowIfCancellationRequested();

      if (!Directory.Exists(modulePath))
      {
        logger?.Debug($"{spec}: Skipping PSModulePath {modulePath} - Configured but does not exist.");
        continue;
      }

      // Case-insensitive search for module base dir
      string? moduleBaseDir = FindSinglePathOrThrow(
          Directory.EnumerateDirectories(modulePath, spec.Name,
              new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive }),
          $"{spec.Name} folder is ambiguous, please delete one");

      if (moduleBaseDir == null)
      {
        logger?.Debug($"{spec}: Skipping PSModulePath {modulePath} - Does not have this module.");
        continue;
      }

      List<(Version version, string path)> candidatePaths = [];
      var manifestName = $"{spec.Name}.psd1";

      NuGetVersion? required = spec.Required;
      if (required != null)
      {
        Version moduleVersion = ResolveFolderVersion(required);
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
          if (!Version.TryParse(leafName, out Version? version))
          {
            logger?.Debug($"Could not parse {folder} in {moduleBaseDir} as a valid version.");
            continue;
          }

          if (spec.Max != null && version > spec.Max.Version)
          {
            logger?.Debug($"{spec}: Skipping {folder} - above the upper bound");
            continue;
          }

          if (spec.Min != null)
          {
            var originalParts = (spec.Min.OriginalVersion ?? "").Split('-')[0];
            Version minVersion = Version.TryParse(originalParts, out Version? parsedBase) && parsedBase.Revision == -1
                ? parsedBase
                : spec.Min.Version;
            if (version < minVersion)
            {
              logger?.Debug($"{spec}: Skipping {folder} - {version} is below the lower bound of {minVersion}");
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
        string? classicManifestPath = FindSinglePathOrThrow(
            Directory.EnumerateFiles(moduleBaseDir, manifestName,
                new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive }),
            $"{moduleBaseDir} manifest is ambiguous");
        if (classicManifestPath != null)
        {
          ModuleFastInfo classicManifest = await PSDataFileReader.ImportModuleManifest(classicManifestPath, ct, logger).ConfigureAwait(false);
          Version manifestVersion = classicManifest.ModuleVersion.Version;

          logger?.Debug($"{spec}: Found classic module {manifestVersion} at {moduleBaseDir}");
          candidatePaths.Add((manifestVersion, moduleBaseDir));
        }
      }

      if (candidatePaths.Count == 0)
      {
        logger?.Debug($"{spec}: Skipping PSModulePath {modulePath} - No installed versions matched the spec.");
        continue;
      }

      foreach ((Version? version, string? folder) in candidatePaths)
      {
        if (File.Exists(Path.Combine(folder, ".incomplete")))
        {
          logger?.Warning($"{spec}: Incomplete installation detected at {folder}. Deleting and ignoring.");
          try
          {
            Directory.Delete(folder, true);
          }
          catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
          {
            logger?.Warning($"{spec}: Failed to delete incomplete installation at {folder}: {ex.Message}");
          }
          continue;
        }

        string? manifestPath = FindSinglePathOrThrow(
            Directory.EnumerateFiles(folder, manifestName,
                new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive }),
            $"{folder} manifest is ambiguous");

        if (manifestPath == null)
        {
          logger?.Warning($"{spec}: Found candidate folder {folder} but no {manifestName} manifest found. This may be a corrupt module.");
          continue;
        }

        ModuleFastInfo manifestCandidate;
        try
        {
          manifestCandidate = await PSDataFileReader
            .ImportModuleManifest(manifestPath, ct, logger).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
          logger?.Warning($"{spec}: Failed to read manifest at {manifestPath}: {ex.Message}");
          continue;
        }

        if (spec.Guid != Guid.Empty && manifestCandidate.Guid != spec.Guid)
        {
          logger?.Warning($"{spec}: Module at {folder} GUID {manifestCandidate.Guid} does not match spec GUID {spec.Guid}.");
          continue;
        }

        NuGetVersion candidateVersion = manifestCandidate.ModuleVersion;

        if (spec.SatisfiedBy(candidateVersion, strictSemVer))
        {
          if (update && spec.Max != candidateVersion)
          {
            logger?.Debug($"{spec}: Skipping {candidateVersion} because -Update was specified and version does not exactly meet upper bound.");
            if (bestCandidates != null &&
                (!bestCandidates.TryGetValue(spec, out ModuleFastInfo? existing) ||
                 manifestCandidate.ModuleVersion > existing.ModuleVersion))
            {
              logger?.Debug($"{spec}: ⬆️ New Best Candidate Version {manifestCandidate.ModuleVersion}");
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