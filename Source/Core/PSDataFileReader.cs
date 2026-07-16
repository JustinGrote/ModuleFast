using System.Collections;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;
using System.Text.RegularExpressions;

using NuGet.Versioning;

namespace ModuleFast;

public static class PSDataFileReader
{

  public static async Task<ModuleFastInfo> ImportModuleManifest(string path, CancellationToken cancelToken = default, CmdletInteraction? cmdlet = null)
  {
    try
    {
      return await ParseModuleManifest(await File.ReadAllTextAsync(path, cancelToken), path, cmdlet);
    }
    catch (Exception ex)
    {
      throw new InvalidOperationException($"Failed to read module manifest at {path}: {ex.Message}", ex);
    }
  }

  public static async Task<ModuleFastInfo> ParseModuleManifest(string content, string location, CmdletInteraction? cmdlet = null)
  {
    Hashtable hashtable = Parse(content, location, cmdlet: cmdlet);
    // Get the prerelease tag from PrivateData
    string? prereleaseTag = null;
    if (hashtable["PrivateData"] is Hashtable privateData)
    {
      privateData = new Hashtable(privateData, StringComparer.InvariantCultureIgnoreCase);

      if (privateData["PSData"] is Hashtable psData)
      {
        psData = new Hashtable(psData, StringComparer.InvariantCultureIgnoreCase);

        if (psData["Prerelease"] is string tag && !string.IsNullOrWhiteSpace(tag))
        {
          prereleaseTag = tag;
        }
      }
    }

    string name = Path.GetFileNameWithoutExtension(location) ?? throw new InvalidDataException($"Invalid module manifest: Name is missing or could not be determined from the file name {location}");
    object? moduleVersionObject = hashtable["ModuleVersion"];
    string moduleVersion = moduleVersionObject switch
    {
      string moduleVersionString => moduleVersionString,
      Version moduleVersionValue => moduleVersionValue.ToString(),
      _ => throw new InvalidDataException("Invalid module manifest: ModuleVersion is missing or not a supported type.")
    };
    string? prerelease = prereleaseTag;
    Guid guid = hashtable["Guid"] switch
    {
      Guid guidValue => guidValue,
      string guidString when Guid.TryParse(guidString, out Guid parsedGuid) => parsedGuid,
      _ => Guid.Empty
    };

    string nugetVersionString = prerelease is not null ? $"{moduleVersion}-{prerelease}" : moduleVersion;

    NuGetVersion version = NuGetVersion.Parse(nugetVersionString);

    return new ModuleFastInfo(name, version, new Uri(location))
    {
      Guid = guid
    };
  }

  public static async Task<Hashtable> Import(string path, CancellationToken cancelToken = default, CmdletInteraction? cmdlet = null)
  {
    try
    {
      return Parse(await File.ReadAllTextAsync(path, cancelToken), path, cancelToken, cmdlet);
    }
    catch (Exception ex)
    {
      throw new InvalidOperationException($"Failed to read data file at {path}: {ex.Message}", ex);
    }
  }

  public static Hashtable Parse(string content, string path, CancellationToken cancelToken = default, CmdletInteraction? cmdlet = null)
  {
    cmdlet?.Debug($"Parsing PowerShell data file: {path}");

    ScriptBlockAst ast = Parser.ParseInput(content, out _, out ParseError[] errors);
    if (errors.Length > 0)
      throw new InvalidOperationException($"Failed to parse module manifest: {string.Join(", ", errors.Select(e => e.Message))}");

    HashtableAst? hashtableAst = ast.Find(static a => a is HashtableAst, false) as HashtableAst;

    if (hashtableAst is null)
      throw new InvalidOperationException("Invalid module manifest: a top-level hashtable was not found.");

    Hashtable? hashtable;
    try
    {
      // Get the key values for Name, ModuleVersion, and Guid from the hashtable
      hashtable = hashtableAst.SafeGetValue() as Hashtable;
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("Cannot generate a PowerShell object for a ScriptBlock evaluating dynamic expressions"))
    {
      cmdlet?.Debug($"{path} is a Manifest with dynamic expressions. Attempting to safe evaluate...");
      Runspace? previousRunspace = Runspace.DefaultRunspace;
      Runspace? temporaryRunspace = null;
      var scriptBlock = ScriptBlock.Create(content);
      // Check if a runspace exists on the thread, if not create a temporary one to evaluate the scriptblock
      if (Runspace.DefaultRunspace is null)
      {
        temporaryRunspace = RunspaceFactory.CreateRunspace();
        temporaryRunspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
        temporaryRunspace.Open();
        Runspace.DefaultRunspace = temporaryRunspace;
      }

      try
      {
        scriptBlock.CheckRestrictedLanguage([], ["PSEdition", "PSScriptRoot"], true);
        cancelToken.ThrowIfCancellationRequested();
        object? evaluatedDataFile = scriptBlock.InvokeReturnAsIs();
        hashtable = evaluatedDataFile switch
        {
          Hashtable evaluatedHashtable => evaluatedHashtable,
          IDictionary evaluatedDictionary => new Hashtable(evaluatedDictionary),
          PSObject { BaseObject: Hashtable baseHashtable } => baseHashtable,
          PSObject { BaseObject: IDictionary baseDictionary } => new Hashtable(baseDictionary),
          _ => null
        };
        cancelToken.ThrowIfCancellationRequested();
      }
      finally
      {
        Runspace.DefaultRunspace = previousRunspace;
        temporaryRunspace?.Dispose();
      }
    }

    if (hashtable is null)
      throw new InvalidOperationException("Invalid module manifest: the top-level hashtable could not be evaluated.");

    // We need to make sure the hashtable is case-insensitive, as module manifests are case-insensitive.
    return new Hashtable(hashtable, StringComparer.InvariantCultureIgnoreCase);
  }

  /// <summary>
  /// Fast scan of a .psd1 file to read only the ModuleVersion line without full parse.
  /// Uses <see cref="FileOptions.SequentialScan"/> to hint sequential access to the OS.
  /// </summary>
  public static Version? TryReadModuleVersionFast(string manifestPath)
  {
    if (!File.Exists(manifestPath)) return null;
    FileStreamOptions streamOptions = new()
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
      Match m = Regex.Match(line,
          @"\s*ModuleVersion\s*=\s*['""](?<version>.+?)['""]");
      if (m.Success && Version.TryParse(m.Groups["version"].Value, out Version? v))
        return v;
    }
    return null;
  }
}