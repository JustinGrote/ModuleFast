using System.Collections;
using System.Text.RegularExpressions;

using NuGet.Versioning;

namespace ModuleFast;

public static class ModuleManifestReader
{
  /// <summary>
  /// The psd1 parser implementation to use. Must be set by the host (PowerShell or Console)
  /// before calling ImportModuleManifest.
  /// </summary>
  public static IPsd1Parser? Parser { get; set; }

  /// <summary>
  /// Imports a module manifest (psd1) and returns its contents as a Hashtable.
  /// </summary>
  public static Hashtable ImportModuleManifest(string path, IModuleFastLogger? logger = null)
  {
    if (!File.Exists(path))
      throw new FileNotFoundException($"Manifest file was not found: {path}", path);

    if (Parser == null)
      throw new InvalidOperationException("ModuleManifestReader.Parser must be set before reading manifests. Set it to an IPsd1Parser implementation.");

    logger?.Debug($"Parsing manifest: {path}");
    return Parser.ParseFile(path);
  }

  /// <summary>
  /// Converts a manifest file path to a ModuleFastInfo object.
  /// </summary>
  public static ModuleFastInfo ConvertFromModuleManifest(string manifestPath, IModuleFastLogger? logger = null)
  {
    var manifestName = Path.GetFileNameWithoutExtension(manifestPath);
    Hashtable manifestData = ImportModuleManifest(manifestPath, logger);

    if (!Version.TryParse(manifestData["ModuleVersion"]?.ToString() ?? "", out Version? manifestVersionData))
      throw new InvalidDataException($"The manifest at {manifestPath} has an invalid ModuleVersion. This is probably an invalid or corrupt manifest");

    var prerelease = (manifestData["PrivateData"] as Hashtable)?["PSData"] is Hashtable psData
        ? psData["Prerelease"]?.ToString()
        : null;

    NuGetVersion manifestVersion = new NuGetVersion(manifestVersionData, prerelease);
    ModuleFastInfo info = new ModuleFastInfo(manifestName, manifestVersion, new Uri(manifestPath));

    if (manifestData["GUID"] is string guidStr && Guid.TryParse(guidStr, out Guid guid))
      info.Guid = guid;

    return info;
  }

  /// <summary>
  /// Fast scan of a .psd1 file to read only the ModuleVersion line without full parse.
  /// Uses <see cref="FileOptions.SequentialScan"/> to hint sequential access to the OS.
  /// </summary>
  public static Version? TryReadModuleVersionFast(string manifestPath)
  {
    if (!File.Exists(manifestPath)) return null;
    FileStreamOptions streamOptions = new FileStreamOptions
    {
      Mode = FileMode.Open,
      Access = FileAccess.Read,
      Share = FileShare.Read,
      Options = FileOptions.SequentialScan,
    };
    using StreamReader reader = new StreamReader(manifestPath, streamOptions);
    string? line;
    while ((line = reader.ReadLine()) != null)
    {
      Match m = System.Text.RegularExpressions.Regex.Match(line,
          @"\s*ModuleVersion\s*=\s*['""](?<version>.+?)['""]");
      if (m.Success && Version.TryParse(m.Groups["version"].Value, out Version? v))
        return v;
    }
    return null;
  }
}