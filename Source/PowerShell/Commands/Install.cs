using System.Management.Automation;
using System.Text.Json;
using System.Threading;

using static System.IO.Path;

namespace ModuleFast.Commands;

[Cmdlet(VerbsLifecycle.Install, "ModuleFast",
    DefaultParameterSetName = "Specification")]
[OutputType(typeof(ModuleFastInfo))]
public class InstallModuleFastCommand : TaskCmdlet
{
  [Alias("Name", "ModuleToInstall", "ModulesToInstall")]
  [AllowNull]
  [AllowEmptyCollection]
  [Parameter(Position = 0, ValueFromPipeline = true, ParameterSetName = "Specification")]
  public ModuleFastSpec[]? Specification { get; set; }

  [Parameter(Mandatory = true, ParameterSetName = "Path")]
  public string? Path { get; set; }

  [Parameter(ParameterSetName = "Path")]
  public SpecFileType SpecFileType { get; set; } = SpecFileType.AutoDetect;

  [Parameter]
  public string? Destination { get; set; }

  [Parameter]
  public string Source { get; set; } = "https://pwsh.gallery/index.json";

  [Parameter]
  public PSCredential? Credential { get; set; }

  [Parameter]
  public SwitchParameter NoPSModulePathUpdate { get; set; }

  [Parameter]
  public SwitchParameter NoProfileUpdate { get; set; }

  [Parameter]
  public SwitchParameter Update { get; set; }

  [Parameter]
  public SwitchParameter Prerelease { get; set; }

  [Parameter]
  public SwitchParameter CI { get; set; }

  [Parameter]
  public SwitchParameter DestinationOnly { get; set; }

  [Parameter]
  public int ThrottleLimit { get; set; } = Environment.ProcessorCount;

  [Parameter]
  public string CILockFilePath { get; set; } = "requires.lock.json";

  [Parameter(Mandatory = true, ValueFromPipeline = true, ParameterSetName = "ModuleFastInfo")]
  public ModuleFastInfo[]? ModuleFastInfo { get; set; }

  [Parameter]
  public SwitchParameter Plan { get; set; }

  [Parameter]
  public SwitchParameter PassThru { get; set; }

  [Parameter]
  public InstallScope? Scope { get; set; }

  [Parameter]
  public int Timeout { get; set; } = 30;

  [Parameter]
  public SwitchParameter StrictSemVer { get; set; }

  private readonly HashSet<ModuleFastSpec> _modulesToInstall = [];
  private readonly List<ModuleFastInfo> _installPlan = [];
  private readonly ModuleFastMessageBuffer _messages = new();
  private CancellationTokenSource? _timeoutSource;
  private HttpClient? _httpClient;

  protected override async Task Begin()
  {
    // Resolve CILockFilePath relative to PowerShell's current location
    if (!IsPathRooted(CILockFilePath))
    {
      CILockFilePath = GetFullPath(Combine(
          SessionState.Path.CurrentFileSystemLocation.Path, CILockFilePath));
    }

    if (Update) ModuleFastCache.Instance.Clear();

    // Normalize source
    if (Uri.TryCreate(Source, UriKind.Absolute, out Uri? srcUri) &&
        srcUri.Scheme is not "http" and not "https")
    {
      Source = $"https://{Source}/index.json";
    }

    var defaultRepoPath = Combine(
        Environment.GetFolderPath(
          Environment.SpecialFolder.LocalApplicationData),
          "powershell",
          "Modules"
        );

    if (string.IsNullOrEmpty(Destination))
    {
      // Map scope to destination
      if (Scope == InstallScope.CurrentUser)
      {
        // Use legacy documents path
        var docsPath = Combine(
          Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
          "PowerShell", "Modules");
        Destination = docsPath;
      }
      else
      {
        Destination = PathHelper.GetPSDefaultModulePath(allUsers: Scope == InstallScope.AllUsers);

        if (OperatingSystem.IsWindows() && Scope != InstallScope.CurrentUser)
        {
          var defaultWindowsPath = Combine(
            Environment.GetFolderPath(
              Environment.SpecialFolder.MyDocuments),
              "PowerShell",
              "Modules"
            );
          if (string.Equals(Destination, defaultWindowsPath, StringComparison.OrdinalIgnoreCase))
          {
            WriteDebug($"Windows Documents module folder detected. Changing to {defaultRepoPath}");
            Destination = defaultRepoPath;
          }
        }
      }
    }
    else
    {
      // User explicitly specified a non-standard destination; don't touch the profile.
      NoProfileUpdate = true;
    }

    if (string.IsNullOrEmpty(Destination))
      ThrowTerminatingError(new ErrorRecord(
          new InvalidOperationException("Failed to determine destination path."),
          "DestinationNotFound", ErrorCategory.InvalidOperation, null));

    // Resolve relative Destination against PowerShell's current location
    if (!IsPathRooted(Destination))
    {
      Destination = GetFullPath(Combine(
          SessionState.Path.CurrentFileSystemLocation.Path, Destination));
    }

    if (!Directory.Exists(Destination))
    {
      if (string.Equals(Destination, defaultRepoPath, StringComparison.OrdinalIgnoreCase) ||
          ((IHostInteraction)this).Confirm(Destination, "Create Destination Folder"))
      {
        Directory.CreateDirectory(Destination!);
      }
    }

    if (!NoPSModulePathUpdate)
    {
      var modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
          .Split(PathSeparator, StringSplitOptions.RemoveEmptyEntries);
      if (!modulePaths.Contains(Destination, StringComparer.OrdinalIgnoreCase))
      {
        PathHelper.AddDestinationToPSModulePath(Destination, NoProfileUpdate, this);
      }
    }

    _httpClient = ModuleFastClient.Create(Credential?.GetNetworkCredential(), Timeout);
    _timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(PipelineStopToken);
    _timeoutSource.CancelAfter(TimeSpan.FromSeconds(Timeout * 10)); // overall timeout
  }

  protected override async Task Process()
  {
    switch (ParameterSetName)
    {
      case "Specification":
        foreach (ModuleFastSpec spec in Specification ?? [])
        {
          if (!_modulesToInstall.Add(spec))
            WriteWarning($"{spec} was specified twice, skipping duplicate.");
        }
        break;

      case "ModuleFastInfo":
        foreach (ModuleFastInfo info in ModuleFastInfo ?? [])
          _installPlan.Add(info);
        break;

      case "Path":
        var paths = new List<string>();
        if (string.IsNullOrEmpty(Path)) break;

        var pathItem = new FileInfo(Path!);
        if (pathItem.Attributes.HasFlag(FileAttributes.Directory))
        {
          paths.AddRange(SpecFileReader.FindRequiredSpecFiles(Path!));
        }
        else
        {
          paths.Add(Path!);
        }

        foreach (var p in paths)
        {
          ModuleFastSpec[] specs = SpecFileReader.ConvertFromRequiredSpec(p, SpecFileType, (IModuleFastLogger)this);
          foreach (ModuleFastSpec spec in specs)
            _modulesToInstall.Add(spec);
        }
        break;
    }
  }

  protected override async Task End()
  {
    try
    {
      CancellationToken ct = _timeoutSource?.Token ?? PipelineStopToken;

      ModuleFastInfo[] finalInstallPlan;

      if (_installPlan.Count > 0)
      {
        finalInstallPlan = _installPlan.ToArray();
      }
      else
      {
        // Auto-detect spec files if nothing was specified
        if (_modulesToInstall.Count == 0 && ParameterSetName == "Specification")
        {
          Verbose("🔎 No modules specified. Beginning SpecFile detection...");

          if (CI && File.Exists(CILockFilePath))
          {
            WriteDebug($"Found lockfile at {CILockFilePath}. Using for specification evaluation.");
            ModuleFastSpec[] lockSpecs = SpecFileReader.ConvertFromRequiredSpec(CILockFilePath, SpecFileType.AutoDetect, (IModuleFastLogger)this);
            foreach (ModuleFastSpec spec in lockSpecs)
              _modulesToInstall.Add(spec);
            if (Update)
            {
              Verbose("-Update specified but lockfile found. Ignoring -Update.");
              Update = false;
            }
          }
          else
          {
            IEnumerable<string> specFiles = SpecFileReader.FindRequiredSpecFiles(SessionState.Path.CurrentFileSystemLocation.Path);
            if (specFiles == null || !specFiles.Any())
            {
              Warning($"No specfiles found in {SessionState.Path.CurrentFileSystemLocation}.");
            }
            else
            {
              foreach (var specFile in specFiles)
              {
                Verbose($"Found Specfile {specFile}. Evaluating...");
                ModuleFastSpec[] fileSpecs = SpecFileReader.ConvertFromRequiredSpec(specFile, SpecFileType, (IModuleFastLogger)this);
                foreach (ModuleFastSpec spec in fileSpecs)
                  _modulesToInstall.Add(spec);
              }
            }
          }
        }

        if (_modulesToInstall.Count == 0)
          ThrowTerminatingError(new ErrorRecord(
              new InvalidDataException("No module specifications found to evaluate."),
              "NoSpecifications", ErrorCategory.InvalidData, null));

        Progress("Install-ModuleFast", "Plan", percentComplete: 1);

        string[] modulePaths;
        if (DestinationOnly)
          modulePaths = [Destination!];
        else
          modulePaths = Environment.GetEnvironmentVariable("PSModulePath")
              ?.Split(PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];

        var planner = new ModuleFastPlanner(_httpClient!, Source);
        Task<HashSet<ModuleFastInfo>> planTask = planner.GetPlanAsync(
          _modulesToInstall, modulePaths, Update, Prerelease, StrictSemVer, DestinationOnly, ct, _messages);
        HashSet<ModuleFastInfo> planSet = planTask.GetAwaiter().GetResult();
        _messages.Flush(this);
        finalInstallPlan = planSet.ToArray();
      }

      if (finalInstallPlan.Length == 0)
      {
        var msg = $"✅ {_modulesToInstall.Count} Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update";
        Verbose(msg);
        return;
      }

      if (Plan || !((IHostInteraction)this).Confirm(Destination!, $"Install {finalInstallPlan.Length} Modules"))
      {
        if (Plan)
          Verbose($"📑 -Plan was specified. Returning a plan including {finalInstallPlan.Length} Module Specifications");
        foreach (ModuleFastInfo info in finalInstallPlan)
          WriteObject(info);
      }
      else
      {
        var total = finalInstallPlan.Length;
        var completed = 0;
        Progress("Install-ModuleFast", $"Installing 0/{total} Modules", percentComplete: 50);

        // The callback is invoked synchronously on the completing thread pool thread.
        // WriteProgress is thread-safe in PowerShell's runtime infrastructure.
        var updateInstallProgress = new Action<ModuleFastInfo>(_ =>
        {
          var done = Interlocked.Increment(ref completed);
          var pct = (done / total * 50) + 50;
          Progress("Install-ModuleFast", $"Installing {done}/{total} Modules", percentComplete: pct);
        });

        var installer = new ModuleFastInstaller(_httpClient!);
        Task<List<ModuleFastInfo>> installTask = installer.InstallModulesAsync(
          finalInstallPlan,
          Destination!,
          Update || ParameterSetName == "ModuleFastInfo",
          ct,
          _messages,
          ThrottleLimit,
          updateInstallProgress
        );
        IEnumerable<ModuleFastInfo> installedModules = installTask.GetAwaiter().GetResult();
        _messages.Flush((IModuleFastLogger)this);

        Verbose("✅ All required modules installed! Exiting.");

        if (PassThru)
          foreach (ModuleFastInfo m in installedModules)
            WriteObject(m);

        if (CI)
        {
          Verbose($"Writing lockfile to {CILockFilePath}");
          var lockFile = new Dictionary<string, string>();
          foreach (ModuleFastInfo m in finalInstallPlan)
            lockFile[m.Name] = m.ModuleVersion.ToString();

          var json = JsonSerializer.Serialize(lockFile, new JsonSerializerOptions { WriteIndented = true });
          File.WriteAllText(CILockFilePath, json);
        }
      }
    }
    catch (Exception ex) when (ex is not PipelineStoppedException)
    {
      ThrowTerminatingError(new ErrorRecord(ex, "InstallModuleFastFailed", ErrorCategory.NotSpecified, null));
    }
    finally
    {
      // Ensure progress is always completed
      Progress("Install-ModuleFast", "Done", percentComplete: 100);
      _timeoutSource?.Dispose();
    }
  }
}