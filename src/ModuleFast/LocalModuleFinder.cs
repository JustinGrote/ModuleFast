using System.Management.Automation;
using System.Text.RegularExpressions;
using NuGet.Versioning;

namespace ModuleFast;

public static class LocalModuleFinder
{
    /// <summary>
    /// Resolves the folder version from a NuGetVersion: 4-part stays as-is, 3-part strips trailing .0.
    /// </summary>
    public static Version ResolveFolderVersion(NuGetVersion version)
    {
        if (version.IsLegacyVersion ||
            Regex.IsMatch(version.OriginalVersion ?? "", @"^\d+\.\d+\.\d+\.\d+$"))
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
        PSCmdlet? cmdlet = null)
    {
        if (modulePaths == null || modulePaths.Length == 0)
        {
            cmdlet?.WriteWarning("No PSModulePaths found. If you are doing isolated testing you can disregard this.");
            return null;
        }

        foreach (var modulePath in modulePaths)
        {
            if (!Directory.Exists(modulePath))
            {
                cmdlet?.WriteDebug($"{spec}: Skipping PSModulePath {modulePath} - Configured but does not exist.");
                continue;
            }

            // Case-insensitive search for module base dir
            var moduleDirs = Directory.GetDirectories(modulePath, spec.Name,
                new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive });

            if (moduleDirs.Length > 1)
                throw new InvalidOperationException($"{spec.Name} folder is ambiguous, please delete one: {string.Join(", ", moduleDirs)}");
            if (moduleDirs.Length == 0)
            {
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
                var manifestPath = Path.Combine(moduleFolder, manifestName);
                if (Directory.Exists(moduleFolder))
                    candidatePaths.Add((moduleVersion, moduleFolder));
            }
            else
            {
                // Enumerate versioned sub-folders
                foreach (var folder in Directory.GetDirectories(moduleBaseDir))
                {
                    var leafName = Path.GetFileName(folder);
                    if (!Version.TryParse(leafName, out var version))
                    {
                        cmdlet?.WriteDebug($"Could not parse {folder} in {moduleBaseDir} as a valid version.");
                        continue;
                    }

                    if (spec.Max != null && version > spec.Max.Version)
                    {
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
                    var classicData = ModuleManifestReader.ImportModuleManifest(classicManifestPath, cmdlet);
                    if (Version.TryParse(classicData["ModuleVersion"]?.ToString() ?? "", out var classicVersion))
                    {
                        cmdlet?.WriteDebug($"{spec}: Found classic module {classicVersion} at {moduleBaseDir}");
                        candidatePaths.Add((classicVersion, moduleBaseDir));
                    }
                }
            }

            if (candidatePaths.Count == 0)
            {
                cmdlet?.WriteDebug($"{spec}: Skipping PSModulePath {modulePath} - No installed versions matched the spec.");
                continue;
            }

            foreach (var (version, folder) in candidatePaths)
            {
                if (File.Exists(Path.Combine(folder, ".incomplete")))
                {
                    cmdlet?.WriteWarning($"{spec}: Incomplete installation detected at {folder}. Deleting and ignoring.");
                    Directory.Delete(folder, true);
                    continue;
                }

                var manifests = Directory.GetFiles(folder, manifestName,
                    new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive });

                if (manifests.Length > 1)
                    throw new InvalidOperationException($"{folder} manifest is ambiguous: {string.Join(", ", manifests)}");
                if (manifests.Length == 0)
                {
                    cmdlet?.WriteWarning($"{spec}: Found candidate folder {folder} but no {manifestName} manifest found. This may be a corrupt module.");
                    continue;
                }

                ModuleFastInfo manifestCandidate;
                try
                {
                    manifestCandidate = ModuleManifestReader.ConvertFromModuleManifest(manifests[0], cmdlet);
                }
                catch (Exception ex)
                {
                    cmdlet?.WriteWarning($"{spec}: Failed to read manifest at {manifests[0]}: {ex.Message}");
                    continue;
                }

                if (spec.Guid != Guid.Empty && manifestCandidate.Guid != spec.Guid)
                {
                    cmdlet?.WriteWarning($"{spec}: Module at {folder} GUID {manifestCandidate.Guid} does not match spec GUID {spec.Guid}.");
                    continue;
                }

                var candidateVersion = manifestCandidate.ModuleVersion;

                if (spec.SatisfiedBy(candidateVersion, strictSemVer))
                {
                    if (update && spec.Max != candidateVersion)
                    {
                        cmdlet?.WriteDebug($"{spec}: Skipping {candidateVersion} because -Update was specified and version does not exactly meet upper bound.");
                        if (bestCandidates != null &&
                            (!bestCandidates.TryGetValue(spec, out var existing) ||
                             manifestCandidate.ModuleVersion > existing.ModuleVersion))
                        {
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
