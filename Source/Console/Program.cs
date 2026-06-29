using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

using ModuleFast;

var source = "https://pwsh.gallery/index.json";
string? destination = null;
string? specFilePath = null;
bool update = false;
bool prerelease = false;
bool ci = false;
bool plan = false;
bool destinationOnly = false;
bool strictSemVer = false;
int timeout = 30;
int throttleLimit = Environment.ProcessorCount;
string ciLockFilePath = "requires.lock.json";
string? username = null;
string? password = null;

// Parse arguments
for (int i = 0; i < args.Length; i++)
{
	switch (args[i].ToLowerInvariant())
	{
		case "-source" or "--source":
			source = args[++i];
			break;
		case "-destination" or "--destination" or "-d":
			destination = args[++i];
			break;
		case "-path" or "--path" or "-p":
			specFilePath = args[++i];
			break;
		case "-update" or "--update":
			update = true;
			break;
		case "-prerelease" or "--prerelease":
			prerelease = true;
			break;
		case "-ci" or "--ci":
			ci = true;
			break;
		case "-plan" or "--plan":
			plan = true;
			break;
		case "-destinationonly" or "--destinationonly":
			destinationOnly = true;
			break;
		case "-strictsemver" or "--strictsemver":
			strictSemVer = true;
			break;
		case "-timeout" or "--timeout":
			timeout = int.Parse(args[++i]);
			break;
		case "-throttlelimit" or "--throttlelimit":
			throttleLimit = int.Parse(args[++i]);
			break;
		case "-lockfilepath" or "--lockfilepath":
			ciLockFilePath = args[++i];
			break;
		case "-username" or "--username" or "-u":
			username = args[++i];
			break;
		case "-password" or "--password":
			password = args[++i];
			break;
		case "-help" or "--help" or "-h" or "-?":
			PrintUsage();
			return 0;
		default:
			// Positional: treat as module spec
			specFilePath ??= args[i];
			break;
	}
}

// Resolve destination
destination ??= PathHelper.GetPSDefaultModulePath(allUsers: false)
		?? Path.Combine(
				Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
				"powershell", "Modules");

if (!Directory.Exists(destination))
	Directory.CreateDirectory(destination);

// Build credential if provided
NetworkCredential? credential = null;
if (username != null && password != null)
	credential = new NetworkCredential(username, password);

// Create HttpClient
HttpClient httpClient = ModuleFastClient.Create(credential, timeout);

using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout * 10));
CancellationToken ct = cts.Token;

// Collect specs
var specs = new HashSet<ModuleFastSpec>();

if (specFilePath != null)
{
	if (Directory.Exists(specFilePath))
	{
		foreach (var file in SpecFileReader.FindRequiredSpecFiles(specFilePath))
		{
      foreach (ModuleFastSpec spec in SpecFileReader.ConvertFromRequiredSpec(file))
        specs.Add(spec);
    }
	}
	else
	{
    foreach (ModuleFastSpec spec in SpecFileReader.ConvertFromRequiredSpec(specFilePath))
      specs.Add(spec);
  }
}
else
{
	// Auto-detect spec files in current directory
	if (ci && File.Exists(ciLockFilePath))
	{
    Console.WriteLine($"Using lockfile: {ciLockFilePath}");
    foreach (ModuleFastSpec spec in SpecFileReader.ConvertFromRequiredSpec(ciLockFilePath))
      specs.Add(spec);
    update = false;
	}
	else
	{
    IEnumerable<string> specFiles = SpecFileReader.FindRequiredSpecFiles(Environment.CurrentDirectory);
    foreach (var file in specFiles)
    {
      Console.WriteLine($"Found specfile: {file}");
      foreach (ModuleFastSpec spec in SpecFileReader.ConvertFromRequiredSpec(file))
        specs.Add(spec);
    }
	}
}

if (specs.Count == 0)
{
  Console.Error.WriteLine("Error: No module specifications found.");
  return 1;
}

if (update) ModuleFastCache.Instance.Clear();

// Plan
Console.WriteLine($"Planning installation of {specs.Count} module specification(s)...");

string[] modulePaths = destinationOnly
		? [destination]
		: Environment.GetEnvironmentVariable("PSModulePath")
				?.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];

var planner = new ModuleFastPlanner(httpClient, source);
HashSet<ModuleFastInfo> planSet = await planner.GetPlan(specs, modulePaths, update, prerelease, strictSemVer, destinationOnly, ct);
ModuleFastInfo[] installPlan = planSet.ToArray();

if (installPlan.Length == 0)
{
  Console.WriteLine("All module specifications are already satisfied.");
  return 0;
}

if (plan)
{
  Console.WriteLine($"Plan: {installPlan.Length} module(s) to install:");
  foreach (ModuleFastInfo? info in installPlan)
    Console.WriteLine($"  {info.Name} {info.ModuleVersion}");
  return 0;
}

// Install
Console.WriteLine($"Installing {installPlan.Length} module(s) to {destination}...");
ModuleFastInstaller installer = new ModuleFastInstaller(httpClient);
List<ModuleFastInfo> installed = await installer.InstallModules(installPlan, destination, update, ct, maxConcurrency: throttleLimit);

Console.WriteLine($"Installed {installed.Count} module(s).");

if (ci)
{
	var lockFile = new Dictionary<string, string>();
  foreach (ModuleFastInfo? m in installPlan)
    lockFile[m.Name] = m.ModuleVersion.ToString();

  var json = JsonSerializer.Serialize(lockFile, ConsoleJsonContext.Default.DictionaryStringString);
	File.WriteAllText(ciLockFilePath, json);
  Console.WriteLine($"Lockfile written to {ciLockFilePath}");
}

return 0;

static void PrintUsage()
{
  Console.WriteLine("""
    modulefast - Fast PowerShell module installer

    Usage: modulefast [options] [path]

    Options:
      -path, -p <path>          Path to spec file or directory
      -destination, -d <path>   Module install destination
      -source <url>             NuGet v3 source URL
      -update                   Force update check (ignore cache)
      -prerelease               Include prerelease versions
      -ci                       CI mode (use/write lockfile)
      -plan                     Show plan without installing
      -destinationonly           Only check destination for existing modules
      -strictsemver             Use strict SemVer matching
      -timeout <seconds>        HTTP timeout (default: 30)
      -throttlelimit <n>        Max concurrent downloads
      -lockfilepath <path>      CI lockfile path (default: requires.lock.json)
      -username, -u <user>      Credential username
      -password <pass>          Credential password
      -help, -h                 Show this help
    """);
}

[JsonSerializable(typeof(Dictionary<string, string>))]
[JsonSourceGenerationOptions(WriteIndented = true)]
internal partial class ConsoleJsonContext : JsonSerializerContext { }
