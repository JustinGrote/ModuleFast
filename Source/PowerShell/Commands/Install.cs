using System.Linq;
using System.Management.Automation;
using System.Text.Json;
using System.Threading.Channels;

using static System.IO.Path;

namespace ModuleFast.Commands;

[Cmdlet(VerbsLifecycle.Install, "ModuleFast",
  DefaultParameterSetName = "Specification",
  SupportsShouldProcess = true,
  ConfirmImpact = ConfirmImpact.Low
)]
[OutputType(typeof(ModuleFastInfo))]
public class InstallModuleFastCommand : TaskCmdlet
{
  private const int PlanProgressId = 1;
  private const int InstallProgressId = 2;

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
  private CancellationTokenSource? _timeoutSource;
  private bool _destinationExplicitlySpecified;

  private CmdletInteraction cmdletInteractor => new TaskCmdletInteractor(this);

  protected override async Task Begin()
  {
    _destinationExplicitlySpecified = MyInvocation.BoundParameters.ContainsKey(nameof(Destination));

    // Resolve CILockFilePath relative to PowerShell's current location
    if (!IsPathRooted(CILockFilePath))
    {
      CILockFilePath = GetFullPath(Combine(
        SessionState.Path.CurrentFileSystemLocation.Path,
        CILockFilePath
      ));
    }

    if (Update) ModuleFastCache.Instance.Clear();

    // Normalize source
    if (Uri.TryCreate(Source, UriKind.Absolute, out Uri? srcUri) &&
        srcUri.Scheme is not "http" and not "https")
    {
      Source = $"https://{Source}/index.json";
    }

    string defaultRepoPath = Combine(
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
        string docsPath = Combine(
          Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
          "PowerShell", "Modules");
        Destination = docsPath;
      }
      else
      {
        Destination = PathHelper.GetPSDefaultModulePath(allUsers: Scope == InstallScope.AllUsers);

        if (OperatingSystem.IsWindows() && Scope != InstallScope.CurrentUser)
        {
          string defaultWindowsPath = Combine(
            Environment.GetFolderPath(
              Environment.SpecialFolder.MyDocuments),
              "PowerShell",
              "Modules"
            );
          if (string.Equals(Destination, defaultWindowsPath, StringComparison.OrdinalIgnoreCase))
          {
            Debug($"Windows Documents module folder detected. Changing to {defaultRepoPath}");
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
        SessionState.Path.CurrentFileSystemLocation.Path,
        Destination
      ));
    }

    if (!Directory.Exists(Destination))
    {
      if (
        string.Equals(Destination, defaultRepoPath, StringComparison.OrdinalIgnoreCase)
        && await Confirm(Destination, "Create default repository folder").ConfigureAwait(false)
      )
      {
        Directory.CreateDirectory(Destination!);
      }
    }

    if (!NoPSModulePathUpdate)
    {
      string[] modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
          .Split(PathSeparator, StringSplitOptions.RemoveEmptyEntries);
      if (!modulePaths.Contains(Destination, StringComparer.OrdinalIgnoreCase))
      {
        await PathHelper.AddDestinationToPSModulePath(Destination, NoProfileUpdate, cmdletInteractor).ConfigureAwait(false);
      }
    }

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
            Warning($"{spec} was specified twice, skipping duplicate.");
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

        foreach (string p in paths)
        {
          ModuleFastSpec[] specs = SpecFileReader.ConvertFromRequiredSpec(p, SpecFileType, cmdletInteractor);
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
            Debug($"Found lockfile at {CILockFilePath}. Using for specification evaluation.");
            ModuleFastSpec[] lockSpecs = SpecFileReader.ConvertFromRequiredSpec(CILockFilePath, SpecFileType.AutoDetect, cmdletInteractor);
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
              foreach (string specFile in specFiles)
              {
                Verbose($"Found Specfile {specFile}. Evaluating...");
                ModuleFastSpec[] fileSpecs = SpecFileReader.ConvertFromRequiredSpec(specFile, SpecFileType, cmdletInteractor);
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

        Progress("Install-ModuleFast", "Plan", percentComplete: 1, id: PlanProgressId);

        string[] modulePaths;
        if (DestinationOnly)
        {
          modulePaths = [Destination!];
        }
        else if (_destinationExplicitlySpecified)
        {
          IEnumerable<string> allModulePaths = (Environment.GetEnvironmentVariable("PSModulePath")
              ?.Split(PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [])
              .Prepend(Destination!);
          modulePaths = allModulePaths
              .Distinct(StringComparer.OrdinalIgnoreCase)
              .ToArray();
        }
        else
        {
          modulePaths = Environment.GetEnvironmentVariable("PSModulePath")
              ?.Split(PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];
        }

        var planner = new ModuleFastPlanner(Source);
        bool whatIfSpecified = MyInvocation.BoundParameters.TryGetValue("WhatIf", out object? whatIfValue)
            && LanguagePrimitives.IsTrue(whatIfValue);
        bool whatIfPreferenceEnabled = SessionState.PSVariable.GetValue("WhatIfPreference") is bool wp && wp;
        bool whatIfEnabled = whatIfSpecified || whatIfPreferenceEnabled;
        bool confirmSpecified = MyInvocation.BoundParameters.TryGetValue("Confirm", out object? confirmValue);
        bool confirmEnabled = confirmSpecified && LanguagePrimitives.IsTrue(confirmValue);
        bool confirmSuppressed = confirmSpecified && !confirmEnabled;
        ConfirmImpact confirmPreference = SessionState.PSVariable.GetValue("ConfirmPreference") is ConfirmImpact cp
            ? cp
            : ConfirmImpact.High;
        bool confirmationWouldPrompt = !confirmSuppressed && confirmPreference <= ConfirmImpact.Medium;
        // Keep planning and installation separate for deterministic behavior.
        // Streaming install while planning can race with local module discovery.
        bool canStreamDuringPlan = false;

        if (canStreamDuringPlan)
        {
          var installer = new ModuleFastInstaller(Source);
          int streamedInstalledCount = 0;
          Progress("Install-ModuleFast", "Installing while planning", percentComplete: 0, id: InstallProgressId);

          var updateInstallProgress = new Action<ModuleFastInfo>(_ =>
          {
            int done = Interlocked.Increment(ref streamedInstalledCount);
            Progress("Install-ModuleFast", $"Installing {done} module(s)", percentComplete: 0, id: InstallProgressId);
          });

          var stream = Channel.CreateUnbounded<ModuleFastInfo>(new UnboundedChannelOptions
          {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false
          });

          Task<List<ModuleFastInfo>> installStreamTask = installer.InstallModules(
              stream.Reader.ReadAllAsync(ct),
              Destination!,
              Update || ParameterSetName == "ModuleFastInfo",
              ct,
              cmdletInteractor,
              ThrottleLimit,
              updateInstallProgress);

          try
          {
            HashSet<ModuleFastInfo> planSet = await planner.GetPlan(
                _modulesToInstall,
                modulePaths,
                Update,
                Prerelease,
                StrictSemVer,
                DestinationOnly,
                ct,
                cmdlet: cmdletInteractor,
                onModulePlanned: async (module, token) =>
                {
                  await stream.Writer.WriteAsync(module, token).ConfigureAwait(false);
                }).ConfigureAwait(false);

            finalInstallPlan = planSet.OrderBy(static module => module.Name, StringComparer.OrdinalIgnoreCase).ToArray();
            stream.Writer.TryComplete();
            Progress("Install-ModuleFast", "Plan complete", percentComplete: 100, id: PlanProgressId);
          }
          catch (Exception ex)
          {
            stream.Writer.TryComplete(ex);
            throw;
          }

          List<ModuleFastInfo> streamedInstalled = await installStreamTask.ConfigureAwait(false);

          if (finalInstallPlan.Length == 0)
          {
            string msg = $"✅ {_modulesToInstall.Count} Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update";
            Verbose(msg);
            return;
          }

          Verbose("✅ All required modules installed! Exiting.");

          if (PassThru)
            foreach (ModuleFastInfo m in streamedInstalled)
              WriteObject(m);

          if (CI)
          {
            Verbose($"Writing lockfile to {CILockFilePath}");
            var lockFile = new Dictionary<string, string>();
            foreach (ModuleFastInfo m in finalInstallPlan)
              lockFile[m.Name] = m.ModuleVersion.ToString();

            string json = JsonSerializer.Serialize(lockFile, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(CILockFilePath, json);
          }

          return;
        }

        HashSet<ModuleFastInfo> nonStreamingPlanSet = await planner.GetPlan(
          _modulesToInstall, modulePaths, Update, Prerelease, StrictSemVer, DestinationOnly, ct, cmdlet: cmdletInteractor).ConfigureAwait(false);
        finalInstallPlan = nonStreamingPlanSet.OrderBy(static module => module.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        Progress("Install-ModuleFast", "Plan complete", percentComplete: 100, id: PlanProgressId);
      }

      if (finalInstallPlan.Length == 0)
      {
        string msg = $"✅ {_modulesToInstall.Count} Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update";
        Verbose(msg);
        return;
      }

      if (Plan || !await Confirm(Destination!, $"Install {finalInstallPlan.Length} Modules").ConfigureAwait(false))
      {
        if (Plan)
          Verbose($"📑 -Plan was specified. Returning a plan including {finalInstallPlan.Length} Module Specifications");
        foreach (ModuleFastInfo info in finalInstallPlan)
          WriteObject(info);
      }
      else
      {
        int total = finalInstallPlan.Length;
        int completed = 0;
        Progress("Install-ModuleFast", $"Installing 0/{total} Modules", percentComplete: 0, id: InstallProgressId);

        // The callback is invoked synchronously on the completing thread pool thread.
        // WriteProgress is thread-safe in PowerShell's runtime infrastructure.
        var updateInstallProgress = new Action<ModuleFastInfo>(_ =>
        {
          int done = Interlocked.Increment(ref completed);
          int pct = done * 100 / total;
          Progress("Install-ModuleFast", $"Installing {done}/{total} Modules", percentComplete: pct, id: InstallProgressId);
        });

        var installer = new ModuleFastInstaller(Source);
        List<ModuleFastInfo> installedModules = await installer.InstallModules(
          finalInstallPlan,
          Destination!,
          Update || ParameterSetName == "ModuleFastInfo",
          ct,
          cmdletInteractor,
          ThrottleLimit,
          updateInstallProgress
        ).ConfigureAwait(false);

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

          string json = JsonSerializer.Serialize(lockFile, new JsonSerializerOptions { WriteIndented = true });
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
      // Ensure progress records are always completed
      Progress("Install-ModuleFast", "Plan done", percentComplete: 100, id: PlanProgressId, completed: true);
      Progress("Install-ModuleFast", "Install done", percentComplete: 100, id: InstallProgressId, completed: true);
      _timeoutSource?.Dispose();
    }
  }
}