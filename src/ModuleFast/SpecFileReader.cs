using System.Collections;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.PowerShell.Commands;
using NuGet.Versioning;

namespace ModuleFast;

public enum SpecFileType { AutoDetect, ModuleFast, PSResourceGet, PSDepend }

public static class SpecFileReader
{
    private static readonly JsonSerializerOptions _jsonOpts = new() { PropertyNameCaseInsensitive = true };
    private static readonly Regex _psDependExtendedKeyRegex = new(@"^(.+)::(.+)$", RegexOptions.Compiled);

    public static IEnumerable<string> FindRequiredSpecFiles(string path)
    {
        var resolvedPath = Path.GetFullPath(path);
        var requireFiles = Directory.GetFiles(resolvedPath, "*.requires.*")
            .Where(f =>
            {
                var ext = Path.GetExtension(f);
                return ext is ".psd1" or ".ps1" or ".psm1" or ".json" or ".jsonc";
            })
            .ToArray();

        if (requireFiles.Length == 0)
            throw new NotSupportedException($"Could not find any required spec files in {path}. Verify the path is correct or provide Module Specifications.");

        return requireFiles;
    }

    public static SpecFileType SelectRequiredSpecFileType(IDictionary spec)
    {
        foreach (string key in spec.Keys.Cast<object>().Select(k => k?.ToString() ?? ""))
        {
            if (key.Contains("::") || key.Contains("/"))
                return SpecFileType.PSDepend;
            if (key == "PSDependOptions")
                return SpecFileType.PSDepend;

            if (spec[key] is IDictionary valueDict)
            {
                if (valueDict.Contains("DependencyType"))
                    return SpecFileType.PSDepend;
                if (valueDict.Contains("Repository") || valueDict.Contains("Version"))
                    return SpecFileType.PSResourceGet;
            }
        }
        return SpecFileType.ModuleFast;
    }

    public static ModuleFastSpec[] ConvertFromRequiredSpec(
        string requiredSpecPath,
        SpecFileType fileType = SpecFileType.AutoDetect,
        PSCmdlet? cmdlet = null)
    {
        var spec = ReadRequiredSpecFile(requiredSpecPath, cmdlet);
        return ConvertFromObject(spec, fileType, cmdlet);
    }

    private static ModuleFastSpec[] ConvertFromObject(object? requiredSpec, SpecFileType fileType, PSCmdlet? cmdlet)
    {
        if (requiredSpec == null)
            throw new InvalidDataException("Could not evaluate the Required Specification to a known format.");

        // Pass-through types
        if (requiredSpec is ModuleFastSpec[] mfSpecArray) return mfSpecArray;
        if (requiredSpec is ModuleFastSpec mfSpec) return [mfSpec];
        if (requiredSpec is string[] strArray) return strArray.Select(s => new ModuleFastSpec(s)).ToArray();
        if (requiredSpec is string str) return [new ModuleFastSpec(str)];
        if (requiredSpec is ModuleSpecification[] msArray) return msArray.Select(ms => new ModuleFastSpec(ms)).ToArray();
        if (requiredSpec is ModuleSpecification ms2) return [new ModuleFastSpec(ms2)];

        // Convert PSCustomObject/dynamic JSON object to dictionary
        if (requiredSpec is System.Management.Automation.PSObject pso && pso.BaseObject is not IDictionary)
        {
            var ht = new Hashtable(StringComparer.OrdinalIgnoreCase);
            foreach (var prop in pso.Properties)
                ht[prop.Name] = prop.Value;
            requiredSpec = ht;
        }

        if (requiredSpec is IDictionary dict)
        {
            if (fileType == SpecFileType.AutoDetect)
                fileType = SelectRequiredSpecFileType(dict);

            return fileType switch
            {
                SpecFileType.PSDepend => ConvertFromPSDepend(dict, cmdlet),
                SpecFileType.PSResourceGet => ConvertFromPSResourceGet(dict, cmdlet),
                _ => ConvertFromModuleFastDict(dict, cmdlet)
            };
        }

        // Handle arrays
        if (requiredSpec is object[] objArr)
        {
            if (objArr.All(o => o is string))
                return objArr.Cast<string>().Select(s => new ModuleFastSpec(s)).ToArray();
        }

        throw new InvalidDataException("Could not evaluate the Required Specification to a known format.");
    }

    private static ModuleFastSpec[] ConvertFromModuleFastDict(IDictionary dict, PSCmdlet? cmdlet)
    {
        var results = new List<ModuleFastSpec>();
        foreach (DictionaryEntry kv in dict)
        {
            var key = kv.Key?.ToString() ?? throw new InvalidDataException("Keys must be strings");
            var value = kv.Value?.ToString() ?? "";

            if (kv.Value is IDictionary)
                throw new NotSupportedException("ModuleFast SpecFile detected but the value is a hashtable. Try using -SpecFileType parameter if you expected another format.");

            if (kv.Value is not string)
                throw new NotSupportedException("Only strings and hashtables are supported on the right hand side.");

            if (value == "latest")
            {
                results.Add(new ModuleFastSpec(key));
                continue;
            }
            if (NuGetVersion.TryParse(value, out _))
            {
                results.Add(new ModuleFastSpec(key, value));
                continue;
            }
            if (VersionRange.TryParse(value, out var vr) && vr != null)
            {
                results.Add(new ModuleFastSpec(key, vr));
                continue;
            }
            try
            {
                results.Add(new ModuleFastSpec($"{key}{value}"));
            }
            catch
            {
                throw new NotSupportedException($"Could not parse {value} as a valid ModuleFastSpec.");
            }
        }
        return results.ToArray();
    }

    public static ModuleFastSpec[] ConvertFromPSDepend(IDictionary spec, PSCmdlet? cmdlet)
    {
        var initialSpec = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var specCopy = new Hashtable(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry kv in spec)
            specCopy[kv.Key?.ToString() ?? ""] = kv.Value;

        if (specCopy.Contains("PSDependOptions"))
        {
            cmdlet?.WriteDebug("PSDepend Parse: PSDependOptions detected. Removing...");
            if (specCopy["PSDependOptions"] is IDictionary options)
            {
                if (options["DependencyType"] != null)
                    throw new NotSupportedException("PSDepend Parse: Top-Level DependencyType in PSDependOptions is not currently supported.");
                if (options["Target"] != null)
                    cmdlet?.WriteWarning("PSDepend Parse: Target in PSDependOptions is not currently supported.");
            }
            specCopy.Remove("PSDependOptions");
        }

        foreach (DictionaryEntry kv in specCopy)
        {
            var key = kv.Key?.ToString() ?? "";
            if (string.IsNullOrEmpty(key)) continue;

            if (key.Contains("/"))
            {
                cmdlet?.WriteDebug($"PSDepend Parse: Skipping Unsupported GitHub module {key}");
                continue;
            }

            var colonMatch = _psDependExtendedKeyRegex.Match(key);
            if (colonMatch.Success)
            {
                if (colonMatch.Groups[1].Value != "PSGalleryModule")
                {
                    cmdlet?.WriteDebug($"PSDepend Parse: Skipping {key} because its extended type is not PSGalleryModule");
                    continue;
                }
                initialSpec[colonMatch.Groups[2].Value] = kv.Value?.ToString() ?? "latest";
                continue;
            }

            if (kv.Value is string strValue)
            {
                initialSpec[key] = strValue;
                continue;
            }

            if (kv.Value is not IDictionary extValue)
                throw new NotSupportedException("PSDepend Parse: Value target must be a string or hashtable");

            if (extValue["DependencyType"]?.ToString() != "PSGalleryModule")
            {
                cmdlet?.WriteDebug($"PSDepend Parse: Skipping {key} because DependencyType is not PSGalleryModule");
                continue;
            }

            var version = extValue["Version"]?.ToString() ?? "latest";
            var name = extValue["Name"]?.ToString() ?? key;

            if (extValue["Parameters"] is IDictionary parameters)
            {
                if (parameters["AllowPrerelease"] != null)
                    name = $"!{name}";
            }

            initialSpec[name] = version;
        }

        return initialSpec
            .Select(kv => kv.Value == "latest"
                ? new ModuleFastSpec(kv.Key)
                : new ModuleFastSpec(kv.Key, kv.Value))
            .ToArray();
    }

    public static ModuleFastSpec[] ConvertFromPSResourceGet(IDictionary spec, PSCmdlet? cmdlet)
    {
        var initialSpec = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (DictionaryEntry kv in spec)
        {
            var key = kv.Key?.ToString() ?? throw new InvalidDataException("PSResourceGet Parse: Keys must be strings.");

            if (kv.Value is string strValue)
            {
                initialSpec[key] = strValue;
                continue;
            }

            if (kv.Value is not IDictionary extValue)
                throw new NotSupportedException("PSResourceGet Parse: Value target must be a string or hashtable");

            var version = extValue["Version"]?.ToString() ?? "latest";

            if (extValue["Prerelease"] != null)
            {
                cmdlet?.WriteDebug($"PSResourceGet Parse: Prerelease detected for {key}");
                key = $"!{key}";
            }
            if (extValue["Repository"] != null)
                cmdlet?.WriteWarning($"PSResourceGet Parse: Repository specification for {key} is not currently supported.");

            initialSpec[key] = version;
        }

        var results = new List<ModuleFastSpec>();
        foreach (var kv in initialSpec)
        {
            if (kv.Value == "latest")
            {
                results.Add(new ModuleFastSpec(kv.Key));
                continue;
            }

            var value = kv.Value;
            if (value.StartsWith('[') || value.StartsWith('(') || value.Contains('*'))
            {
                results.Add(new ModuleFastSpec(kv.Key, VersionRange.Parse(value)));
            }
            else
            {
                results.Add(new ModuleFastSpec(kv.Key, value));
            }
        }
        return results.ToArray();
    }

    internal static object ReadRequiredSpecFile(string requiredSpecPath, PSCmdlet? cmdlet)
    {
        if (Uri.TryCreate(requiredSpecPath, UriKind.Absolute, out var uri) &&
            uri.Scheme is "http" or "https")
        {
            using var client = new System.Net.Http.HttpClient();
            var content = client.GetStringAsync(requiredSpecPath).GetAwaiter().GetResult();
            if (content.AsSpan().TrimStart().StartsWith("@{".AsSpan()))
            {
                var tempFile = Path.GetTempFileName();
                try
                {
                    File.WriteAllText(tempFile, content);
                    return ModuleManifestReader.ImportModuleManifest(tempFile, cmdlet);
                }
                finally { File.Delete(tempFile); }
            }
            return JsonSerializer.Deserialize<object>(content, _jsonOpts)!;
        }

        var resolvedPath = Path.GetFullPath(requiredSpecPath);
        var extension = Path.GetExtension(resolvedPath).ToLowerInvariant();

        if (extension == ".psd1")
        {
            var manifestData = ModuleManifestReader.ImportModuleManifest(resolvedPath, cmdlet);
            if (manifestData.ContainsKey("ModuleVersion"))
            {
                var reqModules = manifestData["RequiredModules"];
                cmdlet?.WriteDebug("Detected a Module Manifest, evaluating RequiredModules");
                if (reqModules == null)
                    throw new InvalidDataException("The manifest does not have a RequiredModules key so ModuleFast does not know what this module requires.");

                if (reqModules is object[] arr && arr.Length == 0)
                    throw new InvalidDataException("The manifest does not have a RequiredModules key so ModuleFast does not know what this module requires. See Get-Help about_module_manifests for more.");

                // Convert to ModuleSpecification array
                return ConvertRequiredModulesToSpecs(reqModules);
            }
            else
            {
                cmdlet?.WriteDebug("Did not detect a module manifest, passing through as-is");
                return manifestData;
            }
        }

        if (extension is ".ps1" or ".psm1")
        {
            cmdlet?.WriteDebug("PowerShell Script/Module file detected, checking for #Requires");
            var ast = System.Management.Automation.Language.Parser.ParseFile(resolvedPath, out _, out _);
            var requiredModules = ast.ScriptRequirements?.RequiredModules?.ToArray();

            if (requiredModules == null || requiredModules.Length == 0)
                throw new NotSupportedException("The script does not have a #Requires -Module statement so ModuleFast does not know what this module requires. See Get-Help about_requires for more.");

            return requiredModules.Select(ms => new ModuleFastSpec(ms)).ToArray();
        }

        if (extension is ".json" or ".jsonc")
        {
            var content = File.ReadAllText(resolvedPath);
            var json = JsonSerializer.Deserialize<JsonElement>(content, _jsonOpts);
            if (json.ValueKind == JsonValueKind.Array)
            {
                var strings = json.EnumerateArray().Select(e => e.GetString() ?? "").ToArray();
                return strings;
            }
            // Convert to dictionary
            var dict = new Hashtable(StringComparer.OrdinalIgnoreCase);
            foreach (var prop in json.EnumerateObject())
                dict[prop.Name] = prop.Value.ToString();
            return dict;
        }

        throw new NotSupportedException("Only .ps1, .psm1, .psd1, and .json files are supported.");
    }

    private static ModuleFastSpec[] ConvertRequiredModulesToSpecs(object requiredModules)
    {
        if (requiredModules is object[] arr)
        {
            var specs = new List<ModuleFastSpec>();
            foreach (var item in arr)
            {
                if (item is string s)
                    specs.Add(new ModuleFastSpec(s));
                else if (item is ModuleSpecification ms)
                    specs.Add(new ModuleFastSpec(ms));
                else if (item is Hashtable ht)
                    specs.Add(new ModuleFastSpec(new ModuleSpecification(ht)));
                else if (item is System.Management.Automation.PSObject pso)
                {
                    if (pso.BaseObject is ModuleSpecification ms2)
                        specs.Add(new ModuleFastSpec(ms2));
                    else if (pso.BaseObject is string str)
                        specs.Add(new ModuleFastSpec(str));
                }
            }
            return specs.ToArray();
        }
        return [];
    }
}
