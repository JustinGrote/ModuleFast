using System.Collections;
using System.Collections.Concurrent;
using System.IO.Compression;
using System.Management.Automation;

using NuGet.Common;
using NuGet.Configuration;
using NuGet.Protocol.Core.Types;
using NuGet.Versioning;
namespace ModuleFast;

public class ModuleFastInstaller
{
  private readonly SourceRepository _sourceRepository;

  /// <summary>Maximum MemoryStream pre-allocation for a single package download (512 MB).</summary>
  private const int MaxPreallocatedBufferSize = 512 * 1024 * 1024;

  /// <summary>
  /// Performs a case-insensitive search for a .psd1 manifest whose base name matches
  /// <paramref name="moduleName"/> inside <paramref name="directory"/>.
  /// Returns the full path on success, or <see langword="null"/> when no match is found.
  /// </summary>
  private static string? FindManifestPath(string directory, string moduleName)
  {
    EnumerationOptions options = new EnumerationOptions { MatchCasing = MatchCasing.CaseInsensitive };
    string[] matches = Directory.GetFiles(directory, "*.psd1", options)
        .Where(f => string.Equals(Path.GetFileNameWithoutExtension(f), moduleName,
            StringComparison.OrdinalIgnoreCase))
        .ToArray();
    return matches.Length == 1 ? matches[0]
         : matches.Length > 1 ? throw new InvalidOperationException($"Ambiguous manifest in {directory}: {string.Join(", ", matches)}")
         : null;
  }

  public ModuleFastInstaller(string source)
  {
    _sourceRepository = new SourceRepository(
        new PackageSource(source),
        Repository.Provider.GetCoreV3());
  }

  /// <summary>
  /// Installs all <paramref name="modules"/> in parallel from an async stream,
  /// capping concurrency at <paramref name="maxConcurrency"/> simultaneous operations.
  /// </summary>
  public async Task<List<ModuleFastInfo>> InstallModules(
      IAsyncEnumerable<ModuleFastInfo> modules,
      string destination,
      bool update,
      CancellationToken ct,
      CmdletInteraction? cmdlet = null,
      int maxConcurrency = 0,
      Action<ModuleFastInfo>? onModuleInstalled = null)
  {
    if (maxConcurrency <= 0)
      maxConcurrency = -1; // Default to unbounded concurrency

    FindPackageByIdResource findPackageByIdResource = await _sourceRepository
        .GetResourceAsync<FindPackageByIdResource>(ct)
        .ConfigureAwait(false);

    ConcurrentBag<ModuleFastInfo> results = [];
    ParallelOptions opts = new()
    {
      MaxDegreeOfParallelism = maxConcurrency,
      CancellationToken = ct
    };

    await Parallel.ForEachAsync(modules, opts, async (m, ct) =>
    {
      ModuleFastInfo? result = await InstallSingleAsync(m, destination, update, findPackageByIdResource, ct, cmdlet)
          .ConfigureAwait(false);
      if (result != null)
      {
        results.Add(result);
        onModuleInstalled?.Invoke(result);
      }
    }).ConfigureAwait(false);

    return results.ToList();
  }

  /// <summary>
  /// Installs all <paramref name="modules"/> in parallel using
  /// <see cref="Parallel.ForEachAsync"/>, capping concurrency at
  /// <paramref name="maxConcurrency"/> simultaneous operations.
  /// </summary>
  public async Task<List<ModuleFastInfo>> InstallModules(
      IEnumerable<ModuleFastInfo> modules,
      string destination,
      bool update,
      CancellationToken ct,
      CmdletInteraction? cmdlet = null,
      int maxConcurrency = 0,
      Action<ModuleFastInfo>? onModuleInstalled = null)
  {
    return await InstallModules(modules.ToAsyncEnumerable(), destination, update, ct, cmdlet, maxConcurrency, onModuleInstalled)
        .ConfigureAwait(false);
  }

  private async Task<ModuleFastInfo?> InstallSingleAsync(
      ModuleFastInfo module,
      string destination,
      bool update,
      FindPackageByIdResource findPackageByIdResource,
      CancellationToken ct,
      CmdletInteraction? cmdlet)
  {
    string installPath = Path.Combine(destination, module.Name,
        LocalModuleFinder.ResolveFolderVersion(module.ModuleVersion).ToString());
    string installIndicatorPath = Path.Combine(installPath, ".incomplete");

    if (File.Exists(installIndicatorPath))
    {
      cmdlet?.Warning($"{module}: Incomplete installation found at {installPath}. Will delete and retry.");
      Directory.Delete(installPath, true);
    }

    if (Directory.Exists(installPath))
    {
      string existingManifestPath = FindManifestPath(installPath, module.Name)
          ?? throw new FileNotFoundException(
              $"{module}: Existing module folder found at {installPath} but no manifest matching '{module.Name}.psd1' could be found.",
              Path.Combine(installPath, $"{module.Name}.psd1"));

      ModuleFastInfo existingManifest = await PSDataFileReader
        .ImportModuleManifest(existingManifestPath, ct, cmdlet)
        .ConfigureAwait(false);

      NuGetVersion existingVersion = existingManifest.ModuleVersion;

      if (module.ModuleVersion == existingVersion)
      {
        if (update)
        {
          cmdlet?.Debug($"{module}: Existing module found at {installPath} and version matches. -Update was specified so assuming same version and skipping.");
          return null;
        }
        else
        {
          throw new NotImplementedException($"{module}: Existing module found at {installPath} and version {existingVersion} is the same. This is probably a bug. Use -Update to override.");
        }
      }

      if (module.ModuleVersion < existingVersion)
        throw new NotSupportedException($"{module}: Existing module found at {installPath} and its version {existingVersion} is newer than the requested version {module.ModuleVersion}. If you wish to continue, remove the existing folder or modify your specification.");

      cmdlet?.Warning($"{module}: Planned version {module.ModuleVersion} is newer than existing version {existingVersion} so we will overwrite.");
      Directory.Delete(installPath, true);
    }

    cmdlet?.Verbose($"{module}: Downloading from {module.Location}");
    if (module.Location == null)
      throw new InvalidOperationException($"{module}: No Download Link found. This is a bug.");

    using SourceCacheContext cacheContext = new()
    {
      DirectDownload = true
    };
    using MemoryStream packageStream = new();
    bool packageFound = await findPackageByIdResource.CopyNupkgToStreamAsync(
      module.Name,
      module.ModuleVersion,
      packageStream,
      cacheContext,
      NullLogger.Instance,
      ct).ConfigureAwait(false);
    if (!packageFound)
      throw new InvalidOperationException($"{module}: package content was not found in the configured source.");

    packageStream.Position = 0;

    Directory.CreateDirectory(installPath);

    // WriteThrough ensures the .incomplete marker reaches the OS immediately —
    // critical because it guards against partial installations on crash.
    await using (FileStream indicatorFs = new FileStream(installIndicatorPath, new FileStreamOptions
    {
      Mode = FileMode.Create,
      Access = FileAccess.Write,
      Share = FileShare.None,
      Options = FileOptions.WriteThrough | FileOptions.Asynchronous,
    })) { /* zero-byte sentinel; just creating the file is enough */ }

    // ZipFile.ExtractToDirectoryAsync (.NET 10) uses async file I/O internally and
    // includes built-in zip-slip protection, replacing the custom ExtractZipAsync method.
    await ZipFile.ExtractToDirectoryAsync(packageStream, installPath, overwriteFiles: false, ct).ConfigureAwait(false);

    string manifestPath = FindManifestPath(installPath, module.Name)
      ?? throw new FileNotFoundException(
          $"{module}: Could not find manifest matching '{module.Name}.psd1' in {installPath}.",
          Path.Combine(installPath, $"{module.Name}.psd1"));

    // Verify the module was properly installed by reading the manifest and checking the version.
    ModuleFastInfo installedModuleManifest = await PSDataFileReader
      .ImportModuleManifest(manifestPath, ct, cmdlet)
      .ConfigureAwait(false);

    Version moduleManifestVersion = installedModuleManifest.ModuleVersion.Version;

    if (moduleManifestVersion == null)
    {
      cmdlet?.Warning($"{module}: Could not detect the module manifest version. This module may not install properly if it has trailing zeros.");
    }
    else
    {
      string originalModuleVersion = Path.GetFileName(installPath);
      if (originalModuleVersion != moduleManifestVersion.ToString())
      {
        cmdlet?.Debug($"{module}: Module Manifest Version {moduleManifestVersion} differs from package version {originalModuleVersion}, moving...");
        string installPathRoot = Path.GetDirectoryName(installPath)!;
        string newInstallPath = Path.Combine(installPathRoot, moduleManifestVersion.ToString());

        if (Directory.Exists(newInstallPath))
          Directory.Delete(newInstallPath, true);

        Directory.Move(installPath, newInstallPath);
        installPath = newInstallPath;

        // Update indicator path
        installIndicatorPath = Path.Combine(installPath, ".incomplete");
        // WriteThrough + Asynchronous: durable write that doesn't block the thread on I/O
        await using FileStream origVerFs = new FileStream(
            Path.Combine(installPath, ".originalModuleVersion"),
            new FileStreamOptions
            {
              Mode = FileMode.Create,
              Access = FileAccess.Write,
              Share = FileShare.None,
              Options = FileOptions.WriteThrough | FileOptions.Asynchronous,
            });
        await using StreamWriter origVerWriter = new StreamWriter(origVerFs);
        await origVerWriter.WriteLineAsync(originalModuleVersion).ConfigureAwait(false);

        module = module with { ModuleVersion = new NuGetVersion(moduleManifestVersion.ToString()) };
      }
      else
      {
        cmdlet?.Debug($"{module}: Verified module manifest version matched, no action needed.");
      }
    }

    // Clean up NuGet files — use EnumerateFileSystemEntries to avoid buffering the full listing
    cmdlet?.Debug($"{module}: Cleaning up NuGet files in {installPath}");
    if (string.IsNullOrEmpty(installPath))
      throw new InvalidOperationException("ModuleDestination was not set. This is a bug.");

    foreach (string item in Directory.EnumerateFileSystemEntries(installPath))
    {
      string name = Path.GetFileName(item);
      if (name is "_rels" or "package" or "[Content_Types].xml" ||
          name.EndsWith(".nuspec", StringComparison.OrdinalIgnoreCase))
      {
        if (File.Exists(item)) File.Delete(item);
        else if (Directory.Exists(item)) Directory.Delete(item, true);
      }
    }

    // Remove .incomplete marker
    if (File.Exists(installIndicatorPath))
      File.Delete(installIndicatorPath);

    cmdlet?.Verbose($"{module}: Successfully installed to {installPath}");

    module = module with { Location = new Uri(installPath) };
    return module;
  }
}