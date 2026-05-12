using System.Collections;
using System.Management.Automation;
using System.Management.Automation.Language;

using NuGet.Versioning;

namespace ModuleFast;

public static class ModuleManifestReader
{
  /// <summary>
  /// Imports a module manifest (psd1), handling dynamic expression manifests as well.
  /// </summary>
  public static Hashtable ImportModuleManifest(string path, PSCmdlet? cmdlet = null)
  {
    if (!File.Exists(path))
      throw new FileNotFoundException($"Manifest file was not found: {path}", path);

    Token[] tokens;
    ParseError[] errors;
    var ast = Parser.ParseFile(path, out tokens, out errors);
    if (errors.Length > 0)
      throw new InvalidDataException($"The manifest at {path} could not be parsed as a PowerShell data file");

    HashtableAst dataAst = ast.Find(a => a is HashtableAst, false) as HashtableAst
        ?? throw new InvalidDataException($"The manifest at {path} does not contain a valid hashtable structure");

    try
    {
      var rawResult = dataAst.SafeGetValue();
      return ToHashtable(rawResult) ?? throw new InvalidOperationException("Unexpected null manifest");
    }
    catch (Exception ex) when (IsDynamicExpressionsError(ex))
    {
      cmdlet?.WriteDebug($"{path} is a Manifest with dynamic expressions. Attempting to safe evaluate...");
      var scriptBlock = ScriptBlock.Create(File.ReadAllText(path));
      scriptBlock.CheckRestrictedLanguage([], ["PSEdition", "PSScriptRoot"], true);
      var rawResult = scriptBlock.InvokeReturnAsIs();
      return ToHashtable(rawResult) ?? throw new InvalidOperationException("Dynamic manifest evaluation returned null");
    }
  }

  private static bool IsDynamicExpressionsError(Exception ex)
  {
    const string marker = "dynamic expressions";
    for (var e = ex; e != null; e = e.InnerException)
      if (e.Message.Contains(marker, StringComparison.OrdinalIgnoreCase))
        return true;
    return false;
  }

  private static Hashtable? ToHashtable(object? obj)
  {
    if (obj == null) return null;
    if (obj is Hashtable ht) return ht;
    if (obj is PSObject pso) return ToHashtable(pso.BaseObject);
    if (obj is IDictionary dict)
    {
      var result = new Hashtable(StringComparer.OrdinalIgnoreCase);
      foreach (DictionaryEntry kv in dict)
        result[kv.Key] = kv.Value;
      return result;
    }
    return null;
  }

  /// <summary>
  /// Converts a manifest file path to a ModuleFastInfo object.
  /// </summary>
  public static ModuleFastInfo ConvertFromModuleManifest(string manifestPath, PSCmdlet? cmdlet = null)
  {
    var manifestName = Path.GetFileNameWithoutExtension(manifestPath);
    var manifestData = ImportModuleManifest(manifestPath, cmdlet);

    if (!Version.TryParse(manifestData["ModuleVersion"]?.ToString() ?? "", out var manifestVersionData))
      throw new InvalidDataException($"The manifest at {manifestPath} has an invalid ModuleVersion. This is probably an invalid or corrupt manifest");

    var prerelease = (manifestData["PrivateData"] as Hashtable)?["PSData"] is Hashtable psData
        ? psData["Prerelease"]?.ToString()
        : null;

    var manifestVersion = new NuGetVersion(manifestVersionData, prerelease);
    var info = new ModuleFastInfo(manifestName, manifestVersion, new Uri(manifestPath));

    if (manifestData["GUID"] is string guidStr && Guid.TryParse(guidStr, out var guid))
      info.Guid = guid;

    return info;
  }

  /// <summary>
  /// Fast scan of a .psd1 file to read only the ModuleVersion line without full parse.
  /// </summary>
  public static Version? TryReadModuleVersionFast(string manifestPath)
  {
    if (!File.Exists(manifestPath)) return null;
    using var reader = new StreamReader(manifestPath);
    string? line;
    while ((line = reader.ReadLine()) != null)
    {
      var m = System.Text.RegularExpressions.Regex.Match(line,
          @"\s*ModuleVersion\s*=\s*['""](?<version>.+?)['""]");
      if (m.Success && Version.TryParse(m.Groups["version"].Value, out var v))
        return v;
    }
    return null;
  }
}