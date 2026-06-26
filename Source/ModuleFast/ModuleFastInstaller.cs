using System.IO.Compression;
using System.Management.Automation;

using NuGet.Versioning;
namespace ModuleFast;

public class ModuleFastInstaller
{
  private readonly HttpClient _httpClient;

  /// <summary>Maximum MemoryStream pre-allocation for a single package download (512 MB).</summary>
  private const int MaxPreallocatedBufferSize = 512 * 1024 * 1024;

  /// <summary>Buffer size used when writing individual zip entries to disk (64 KB).</summary>
  private const int DefaultFileStreamBufferSize = 65536;

  public ModuleFastInstaller(HttpClient httpClient)
  {
    _httpClient = httpClient;
  }

  /// <summary>
  /// Installs all <paramref name="modules"/> in parallel, capping concurrency at
  /// <paramref name="maxConcurrency"/> simultaneous operations so that large install
  /// plans don't overwhelm the file system or connection pool.
  /// </summary>
  public async Task<List<ModuleFastInfo>> InstallModulesAsync(
      IEnumerable<ModuleFastInfo> modules,
      string destination,
      bool update,
      CancellationToken ct,
      PSCmdlet? cmdlet = null,
      int maxConcurrency = 0)
  {
    if (maxConcurrency <= 0)
      maxConcurrency = Environment.ProcessorCount;

    using var semaphore = new SemaphoreSlim(maxConcurrency);
    var tasks = modules.Select(async m =>
    {
      await semaphore.WaitAsync(ct).ConfigureAwait(false);
      try
      {
        return await InstallSingleAsync(m, destination, update, ct, cmdlet).ConfigureAwait(false);
      }
      finally
      {
        semaphore.Release();
      }
    });
    var results = await Task.WhenAll(tasks).ConfigureAwait(false);
    return results.Where(r => r != null).Cast<ModuleFastInfo>().ToList();
  }

  private async Task<ModuleFastInfo?> InstallSingleAsync(
      ModuleFastInfo module,
      string destination,
      bool update,
      CancellationToken ct,
      PSCmdlet? cmdlet)
  {
    var installPath = Path.Combine(destination, module.Name,
        LocalModuleFinder.ResolveFolderVersion(module.ModuleVersion).ToString());
    var installIndicatorPath = Path.Combine(installPath, ".incomplete");

    if (File.Exists(installIndicatorPath))
    {
      cmdlet?.WriteWarning($"{module}: Incomplete installation found at {installPath}. Will delete and retry.");
      Directory.Delete(installPath, true);
    }

    if (Directory.Exists(installPath))
    {
      var existingManifestPath = Path.Combine(installPath, $"{module.Name}.psd1");
      if (!File.Exists(existingManifestPath))
        throw new InvalidOperationException($"{module}: Existing module folder found at {installPath} but the manifest could not be found.");

      var existingManifestData = ModuleManifestReader.ImportModuleManifest(existingManifestPath, cmdlet);
      var existingVersionStr = existingManifestData["ModuleVersion"]?.ToString() ?? "0.0.0";
      var prerelease = (existingManifestData["PrivateData"] as System.Collections.Hashtable)?["PSData"] is System.Collections.Hashtable psData
          ? psData["Prerelease"]?.ToString() : null;

      Version.TryParse(existingVersionStr, out var evBase);
      var existingVersion = new NuGetVersion(evBase ?? new Version(0, 0), prerelease);

      if (module.ModuleVersion == existingVersion)
      {
        if (update)
        {
          cmdlet?.WriteDebug($"{module}: Existing module found at {installPath} and version matches. -Update was specified so assuming same version and skipping.");
          return null;
        }
        else
        {
          throw new NotImplementedException($"{module}: Existing module found at {installPath} and version {existingVersion} is the same. This is probably a bug. Use -Update to override.");
        }
      }

      if (module.ModuleVersion < existingVersion)
        throw new NotSupportedException($"{module}: Existing module found at {installPath} and its version {existingVersion} is newer than the requested version {module.ModuleVersion}. If you wish to continue, remove the existing folder or modify your specification.");

      cmdlet?.WriteWarning($"{module}: Planned version {module.ModuleVersion} is newer than existing version {existingVersion} so we will overwrite.");
      Directory.Delete(installPath, true);
    }

    cmdlet?.WriteVerbose($"{module}: Downloading from {module.Location}");
    if (module.Location == null)
      throw new InvalidOperationException($"{module}: No Download Link found. This is a bug.");

    // Use ResponseHeadersRead so we can read Content-Length and pre-allocate the MemoryStream,
    // avoiding repeated buffer resizing for large packages while keeping the download truly async.
    using var response = await _httpClient
        .GetAsync(module.Location, HttpCompletionOption.ResponseHeadersRead, ct)
        .ConfigureAwait(false);
    response.EnsureSuccessStatusCode();

    var contentLength = response.Content.Headers.ContentLength;
    await using var httpStream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);

    // Pre-allocate the MemoryStream using Content-Length when available to avoid repeated
    // internal buffer resizing. Cap at MaxPreallocatedBufferSize to guard against absurdly
    // large or malicious Content-Length values; also guard against overflow when casting to int.
    var preAllocSize = contentLength.HasValue && contentLength.Value > 0
        ? (int)Math.Min(contentLength.Value, MaxPreallocatedBufferSize)
        : 0;
    using var packageStream = preAllocSize > 0 ? new MemoryStream(preAllocSize) : new MemoryStream();
    await httpStream.CopyToAsync(packageStream, ct).ConfigureAwait(false);
    packageStream.Position = 0;

    Directory.CreateDirectory(installPath);
    await File.WriteAllTextAsync(installIndicatorPath, "", ct).ConfigureAwait(false);

    using var zip = new ZipArchive(packageStream, ZipArchiveMode.Read);
    await ExtractZipAsync(zip, installPath, ct).ConfigureAwait(false);

    // Fast scan for manifest version
    var manifestPath = Path.Combine(installPath, $"{module.Name}.psd1");
    var moduleManifestVersion = ModuleManifestReader.TryReadModuleVersionFast(manifestPath);

    if (moduleManifestVersion == null)
    {
      cmdlet?.WriteWarning($"{module}: Could not detect the module manifest version. This module may not install properly if it has trailing zeros.");
    }
    else
    {
      var originalModuleVersion = Path.GetFileName(installPath);
      if (originalModuleVersion != moduleManifestVersion.ToString())
      {
        cmdlet?.WriteDebug($"{module}: Module Manifest Version {moduleManifestVersion} differs from package version {originalModuleVersion}, moving...");
        var installPathRoot = Path.GetDirectoryName(installPath)!;
        var newInstallPath = Path.Combine(installPathRoot, moduleManifestVersion.ToString());

        if (Directory.Exists(newInstallPath))
          Directory.Delete(newInstallPath, true);

        Directory.Move(installPath, newInstallPath);
        installPath = newInstallPath;

        // Update indicator path
        installIndicatorPath = Path.Combine(installPath, ".incomplete");
        await File.WriteAllTextAsync(Path.Combine(installPath, ".originalModuleVersion"), originalModuleVersion, ct)
            .ConfigureAwait(false);

        module.ModuleVersion = new NuGetVersion(moduleManifestVersion.ToString());
      }
      else
      {
        cmdlet?.WriteDebug($"{module}: Module Manifest version matches the expected version.");
      }
    }

    // Verify GUID if specified
    if (module.Guid != Guid.Empty)
    {
      cmdlet?.WriteDebug($"{module}: GUID was specified. Verifying manifest.");
      var manifestData = ModuleManifestReader.ImportModuleManifest(
          Path.Combine(installPath, $"{module.Name}.psd1"), cmdlet);
      if (!Guid.TryParse(manifestData["GUID"]?.ToString() ?? "", out var manifestGuid) ||
          manifestGuid != module.Guid)
      {
        Directory.Delete(installPath, true);
        throw new InvalidOperationException(
            $"{module}: The installed package GUID does not match. Expected {module.Guid} but found {manifestGuid} in {manifestPath}.");
      }
    }

    // Clean up NuGet files
    cmdlet?.WriteDebug($"Cleanup Nuget Files in {installPath}");
    if (string.IsNullOrEmpty(installPath))
      throw new InvalidOperationException("ModuleDestination was not set. This is a bug.");

    foreach (var item in Directory.GetFileSystemEntries(installPath))
    {
      var name = Path.GetFileName(item);
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

    module.Location = new Uri(installPath);
    return module;
  }

  /// <summary>
  /// Extracts all entries of <paramref name="zip"/> to <paramref name="destinationPath"/> using
  /// async file I/O (<see cref="FileOptions.Asynchronous"/>) so that writing large files does not
  /// block thread-pool threads and other concurrent install tasks can make progress on the same
  /// threads while I/O is in flight. Entries are processed sequentially within a single archive
  /// because <see cref="ZipArchive"/> shares one underlying seekable stream across all entries.
  /// </summary>
  private static async Task ExtractZipAsync(ZipArchive zip, string destinationPath, CancellationToken ct)
  {
    // Canonicalise the destination once so every entry comparison is against the same base.
    var destFull = Path.GetFullPath(destinationPath);

    foreach (var entry in zip.Entries)
    {
      ct.ThrowIfCancellationRequested();

      // Normalise the entry's separator to the current OS before combining, so that
      // mixed-separator paths (e.g. Unix-style forward slashes in an archive opened on Windows)
      // are resolved unambiguously by Path.GetFullPath.
      var normalizedEntry = entry.FullName.Replace(
          Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar);
      var entryPath = Path.GetFullPath(Path.Combine(destFull, normalizedEntry));

      // Zip-slip protection: the fully-normalised entry path must remain within the destination.
      // Appending the separator prevents a false prefix match against a sibling directory
      // (e.g. /dest matching /dest-other).
      if (!entryPath.StartsWith(destFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) &&
          !entryPath.Equals(destFull, StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException(
            $"Zip entry '{entry.FullName}' resolves outside the destination directory and was rejected.");

      if (string.IsNullOrEmpty(entry.Name))
      {
        // Directory entry
        Directory.CreateDirectory(entryPath);
        continue;
      }

      var parentDir = Path.GetDirectoryName(entryPath);
      if (!string.IsNullOrEmpty(parentDir))
        Directory.CreateDirectory(parentDir);

      await using var entryStream = entry.Open();
      await using var fileStream = new FileStream(
          entryPath,
          FileMode.Create,
          FileAccess.Write,
          FileShare.None,
          bufferSize: DefaultFileStreamBufferSize,
          FileOptions.Asynchronous);
      await entryStream.CopyToAsync(fileStream, ct).ConfigureAwait(false);
    }
  }
}