using System.Collections;
using System.Collections.Concurrent;
using System.IO.Compression;

using NuGet.Versioning;
namespace ModuleFast;

public class ModuleFastInstaller
{
  private readonly HttpClient _httpClient;

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
    var matches = Directory.GetFiles(directory, "*.psd1", options)
        .Where(f => string.Equals(Path.GetFileNameWithoutExtension(f), moduleName,
            StringComparison.OrdinalIgnoreCase))
        .ToArray();
    return matches.Length == 1 ? matches[0]
         : matches.Length > 1 ? throw new InvalidOperationException(
               $"Ambiguous manifest in {directory}: {string.Join(", ", matches)}")
         : null;
  }

  public ModuleFastInstaller(HttpClient httpClient)
  {
    _httpClient = httpClient;
  }

  /// <summary>
  /// Installs all <paramref name="modules"/> in parallel using
  /// <see cref="Parallel.ForEachAsync"/>, capping concurrency at
  /// <paramref name="maxConcurrency"/> simultaneous operations.
  /// </summary>
  public async Task<List<ModuleFastInfo>> InstallModulesAsync(
      IEnumerable<ModuleFastInfo> modules,
      string destination,
      bool update,
      CancellationToken ct,
      CmdletInteraction? cmdlet = null,
      int maxConcurrency = 0,
      Action<ModuleFastInfo>? onModuleInstalled = null)
  {
    if (maxConcurrency <= 0)
      maxConcurrency = Environment.ProcessorCount;

    ConcurrentBag<ModuleFastInfo> results = [];
    ParallelOptions opts = new() { MaxDegreeOfParallelism = maxConcurrency, CancellationToken = ct };

    await Parallel.ForEachAsync(modules, opts, async (m, ct) =>
    {
      ModuleFastInfo? result = await InstallSingleAsync(m, destination, update, ct, cmdlet).ConfigureAwait(false);
      if (result != null)
      {
        results.Add(result);
        onModuleInstalled?.Invoke(result);
      }
    }).ConfigureAwait(false);

    return results.ToList();
  }

  private async Task<ModuleFastInfo?> InstallSingleAsync(
      ModuleFastInfo module,
      string destination,
      bool update,
      CancellationToken ct,
      CmdletInteraction? messages)
  {
    var installPath = Path.Combine(destination, module.Name,
        LocalModuleFinder.ResolveFolderVersion(module.ModuleVersion).ToString());
    var installIndicatorPath = Path.Combine(installPath, ".incomplete");

    if (File.Exists(installIndicatorPath))
    {
      messages?.Warning($"{module}: Incomplete installation found at {installPath}. Will delete and retry.");
      Directory.Delete(installPath, true);
    }

    if (Directory.Exists(installPath))
    {
      var existingManifestPath = FindManifestPath(installPath, module.Name)
          ?? throw new FileNotFoundException(
              $"{module}: Existing module folder found at {installPath} but no manifest matching '{module.Name}.psd1' could be found.",
              Path.Combine(installPath, $"{module.Name}.psd1"));

      Hashtable existingManifestData = messages != null
        ? ModuleManifestReader.ImportModuleManifest(existingManifestPath, messages)
        : ModuleManifestReader.ImportModuleManifest(existingManifestPath, cmdlet: null);
      var existingVersionStr = existingManifestData["ModuleVersion"]?.ToString() ?? "0.0.0";
      var prerelease = (existingManifestData["PrivateData"] as System.Collections.Hashtable)?["PSData"] is System.Collections.Hashtable psData
          ? psData["Prerelease"]?.ToString() : null;

      Version.TryParse(existingVersionStr, out Version? evBase);
      NuGetVersion existingVersion = new NuGetVersion(evBase ?? new Version(0, 0), prerelease);

      if (module.ModuleVersion == existingVersion)
      {
        if (update)
        {
          messages?.Debug($"{module}: Existing module found at {installPath} and version matches. -Update was specified so assuming same version and skipping.");
          return null;
        }
        else
        {
          throw new NotImplementedException($"{module}: Existing module found at {installPath} and version {existingVersion} is the same. This is probably a bug. Use -Update to override.");
        }
      }

      if (module.ModuleVersion < existingVersion)
        throw new NotSupportedException($"{module}: Existing module found at {installPath} and its version {existingVersion} is newer than the requested version {module.ModuleVersion}. If you wish to continue, remove the existing folder or modify your specification.");

      messages?.Warning($"{module}: Planned version {module.ModuleVersion} is newer than existing version {existingVersion} so we will overwrite.");
      Directory.Delete(installPath, true);
    }

    messages?.Verbose($"{module}: Downloading from {module.Location}");
    if (module.Location == null)
      throw new InvalidOperationException($"{module}: No Download Link found. This is a bug.");

    // Use ResponseHeadersRead so we can read Content-Length and pre-allocate the MemoryStream,
    // avoiding repeated buffer resizing for large packages while keeping the download truly async.
    using HttpResponseMessage response = await _httpClient
        .GetAsync(module.Location, HttpCompletionOption.ResponseHeadersRead, ct)
        .ConfigureAwait(false);
    response.EnsureSuccessStatusCode();

    var contentLength = response.Content.Headers.ContentLength;
    await using Stream httpStream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);

    // Pre-allocate the MemoryStream using Content-Length when available to avoid repeated
    // internal buffer resizing. Guard against overflow: clamp to int.MaxValue before the
    // cast so that this stays correct even if MaxPreallocatedBufferSize is ever raised above 2 GB.
    var preAllocSize = contentLength.HasValue && contentLength.Value > 0
        ? (int)Math.Min(Math.Min(contentLength.Value, MaxPreallocatedBufferSize), int.MaxValue)
        : 0;
    using MemoryStream packageStream = preAllocSize > 0 ? new MemoryStream(preAllocSize) : new MemoryStream();
    await httpStream.CopyToAsync(packageStream, ct).ConfigureAwait(false);
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
    await ZipFile.ExtractToDirectoryAsync(packageStream, installPath, overwriteFiles: false, ct)
        .ConfigureAwait(false);

    // Fast scan for manifest version — use case-insensitive search on Linux/macOS
    var manifestPath = FindManifestPath(installPath, module.Name)
        ?? throw new FileNotFoundException(
            $"{module}: Could not find manifest matching '{module.Name}.psd1' in {installPath}.",
            Path.Combine(installPath, $"{module.Name}.psd1"));
    Version? moduleManifestVersion = ModuleManifestReader.TryReadModuleVersionFast(manifestPath);

    if (moduleManifestVersion == null)
    {
      // Fast reader failed, fall back to full manifest import
      try
      {
        Hashtable fallbackData = ModuleManifestReader.ImportModuleManifest(manifestPath, messages);
        if (Version.TryParse(fallbackData["ModuleVersion"]?.ToString() ?? "", out Version? fallbackVersion))
          moduleManifestVersion = fallbackVersion;
      }
      catch { /* Fall through to warning */ }
    }

    if (moduleManifestVersion == null)
    {
      messages?.Warning($"{module}: Could not detect the module manifest version. This module may not install properly if it has trailing zeros.");
    }
    else
    {
      var originalModuleVersion = Path.GetFileName(installPath);
      if (originalModuleVersion != moduleManifestVersion.ToString())
      {
        messages?.Debug($"{module}: Module Manifest Version {moduleManifestVersion} differs from package version {originalModuleVersion}, moving...");
        var installPathRoot = Path.GetDirectoryName(installPath)!;
        var newInstallPath = Path.Combine(installPathRoot, moduleManifestVersion.ToString());

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

        module.ModuleVersion = new NuGetVersion(moduleManifestVersion.ToString());
      }
      else
      {
        messages?.Debug($"{module}: Module Manifest version matches the expected version.");
      }
    }

    // Verify GUID if specified
    if (module.Guid != Guid.Empty)
    {
      messages?.Debug($"{module}: GUID was specified. Verifying manifest.");
      var guidManifestPath = FindManifestPath(installPath, module.Name)
          ?? throw new FileNotFoundException(
              $"{module}: Manifest not found in {installPath} for GUID verification.",
              Path.Combine(installPath, $"{module.Name}.psd1"));
      Hashtable manifestData = messages != null
          ? ModuleManifestReader.ImportModuleManifest(guidManifestPath, messages)
          : ModuleManifestReader.ImportModuleManifest(guidManifestPath, cmdlet: null);
      if (!Guid.TryParse(manifestData["GUID"]?.ToString() ?? "", out Guid manifestGuid) ||
          manifestGuid != module.Guid)
      {
        Directory.Delete(installPath, true);
        throw new InvalidOperationException(
            $"{module}: The installed package GUID does not match. Expected {module.Guid} but found {manifestGuid} in {guidManifestPath}.");
      }
    }

    // Clean up NuGet files — use EnumerateFileSystemEntries to avoid buffering the full listing
    messages?.Debug($"Cleanup Nuget Files in {installPath}");
    if (string.IsNullOrEmpty(installPath))
      throw new InvalidOperationException("ModuleDestination was not set. This is a bug.");

    foreach (var item in Directory.EnumerateFileSystemEntries(installPath))
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
}