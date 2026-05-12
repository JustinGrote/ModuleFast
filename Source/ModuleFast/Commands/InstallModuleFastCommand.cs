using System.Collections.Generic;
using System.Management.Automation;
using System.Text.Json;
using System.Threading;

namespace ModuleFast.Commands;

[Cmdlet(VerbsLifecycle.Install, "ModuleFast",
    SupportsShouldProcess = true,
    DefaultParameterSetName = "Specification")]
[OutputType(typeof(ModuleFastInfo))]
public class InstallModuleFastCommand : PSCmdlet
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
  public string CILockFilePath { get; set; } = System.IO.Path.Combine(
      Environment.CurrentDirectory, "requires.lock.json");

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

  private readonly HashSet<ModuleFastSpec> _modulesToInstall = new();
  private readonly List<ModuleFastInfo> _installPlan = new();
  private CancellationTokenSource? _cancelSource;
  private System.Net.Http.HttpClient? _httpClient;

  protected override void BeginProcessing()
  {
    if (Update) ModuleFastCache.Instance.Clear();

    // Normalize source
    if (Uri.TryCreate(Source, UriKind.Absolute, out var srcUri) &&
        srcUri.Scheme is not "http" and not "https")
    {
      Source = $"https://{Source}/index.json";
    }

    var defaultRepoPath = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "powershell", "Modules");

    if (string.IsNullOrEmpty(Destination))
    {
      // Map scope to destination
      if (Scope == InstallScope.CurrentUser)
      {
        // Use legacy documents path
        var docsPath = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "PowerShell", "Modules");
        Destination = docsPath;
      }
      else
      {
        Destination = PathHelper.GetPSDefaultModulePath(allUsers: Scope == InstallScope.AllUsers);

        if (OperatingSystem.IsWindows() && Scope != InstallScope.CurrentUser)
        {
          var defaultWindowsPath = System.IO.Path.Combine(
              Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
              "PowerShell", "Modules");
          if (string.Equals(Destination, defaultWindowsPath, StringComparison.OrdinalIgnoreCase))
          {
            WriteDebug($"Windows Documents module folder detected. Changing to {defaultRepoPath}");
            Destination = defaultRepoPath;
          }
        }
      }
    }

    if (string.IsNullOrEmpty(Destination))
      ThrowTerminatingError(new ErrorRecord(
          new InvalidOperationException("Failed to determine destination path."),
          "DestinationNotFound", ErrorCategory.InvalidOperation, null));

    if (!Directory.Exists(Destination))
    {
      if (string.Equals(Destination, defaultRepoPath, StringComparison.OrdinalIgnoreCase) ||
          PathHelper.ApproveAction(Destination, "Create Destination Folder", this))
      {
        Directory.CreateDirectory(Destination!);
      }
    }

    Destination = System.IO.Path.GetFullPath(Destination!);

    if (!NoPSModulePathUpdate)
    {
      var modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
          .Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
      if (!modulePaths.Contains(Destination, StringComparer.OrdinalIgnoreCase))
      {
        PathHelper.AddDestinationToPSModulePath(Destination, NoProfileUpdate, this);
      }
    }

    _httpClient = ModuleFastClient.Create(Credential, Timeout);
    _cancelSource = new CancellationTokenSource();
    _cancelSource.CancelAfter(TimeSpan.FromSeconds(Timeout * 10)); // overall timeout
  }

  protected override void ProcessRecord()
  {
    switch (ParameterSetName)
    {
      case "Specification":
        foreach (var spec in Specification ?? [])
        {
          if (!_modulesToInstall.Add(spec))
            WriteWarning($"{spec} was specified twice, skipping duplicate.");
        }
        break;

      case "ModuleFastInfo":
        foreach (var info in ModuleFastInfo ?? [])
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
          var specs = SpecFileReader.ConvertFromRequiredSpec(p, SpecFileType, this);
          foreach (var spec in specs)
            _modulesToInstall.Add(spec);
        }
        break;
    }
  }

  protected override void EndProcessing()
  {
    try
    {
      var ct = _cancelSource?.Token ?? CancellationToken.None;

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
          WriteVerbose("🔎 No modules specified. Beginning SpecFile detection...");

          if (CI && File.Exists(CILockFilePath))
          {
            WriteDebug($"Found lockfile at {CILockFilePath}. Using for specification evaluation.");
            var lockSpecs = SpecFileReader.ConvertFromRequiredSpec(CILockFilePath, SpecFileType.AutoDetect, this);
            foreach (var spec in lockSpecs)
              _modulesToInstall.Add(spec);
            if (Update)
            {
              WriteVerbose("-Update specified but lockfile found. Ignoring -Update.");
              Update = false;
            }
          }
          else
          {
            var specFiles = SpecFileReader.FindRequiredSpecFiles(Environment.CurrentDirectory);
            if (specFiles == null || !specFiles.Any())
            {
              WriteWarning($"No specfiles found in {Environment.CurrentDirectory}.");
            }
            else
            {
              foreach (var specFile in specFiles)
              {
                WriteVerbose($"Found Specfile {specFile}. Evaluating...");
                var fileSpecs = SpecFileReader.ConvertFromRequiredSpec(specFile, SpecFileType, this);
                foreach (var spec in fileSpecs)
                  _modulesToInstall.Add(spec);
              }
            }
          }
        }

        if (_modulesToInstall.Count == 0)
          ThrowTerminatingError(new ErrorRecord(
              new InvalidDataException("No module specifications found to evaluate."),
              "NoSpecifications", ErrorCategory.InvalidData, null));

        WriteProgress(new ProgressRecord(1, "Install-ModuleFast", "Plan") { PercentComplete = 1 });

        string[] modulePaths;
        if (DestinationOnly)
          modulePaths = [Destination!];
        else
          modulePaths = Environment.GetEnvironmentVariable("PSModulePath")
              ?.Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];

        var planner = new ModuleFastPlanner(_httpClient!, Source);
        var planTask = planner.GetPlanAsync(
            _modulesToInstall, modulePaths, Update, Prerelease, StrictSemVer, DestinationOnly, ct, this);
        var planSet = planTask.GetAwaiter().GetResult();
        finalInstallPlan = planSet.ToArray();
      }

      if (finalInstallPlan.Length == 0)
      {
        var msg = $"✅ {_modulesToInstall.Count} Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update";
        WriteVerbose(msg);
        return;
      }

      if (Plan || !PathHelper.ApproveAction(Destination!, $"Install {finalInstallPlan.Length} Modules", this))
      {
        if (Plan)
          WriteVerbose($"📑 -Plan was specified. Returning a plan including {finalInstallPlan.Length} Module Specifications");
        foreach (var info in finalInstallPlan)
          WriteObject(info);
      }
      else
      {
        WriteProgress(new ProgressRecord(1, "Install-ModuleFast", $"Installing: {finalInstallPlan.Length} Modules") { PercentComplete = 50 });

        var installer = new ModuleFastInstaller(_httpClient!);
        var installTask = installer.InstallModulesAsync(finalInstallPlan, Destination!, Update || ParameterSetName == "ModuleFastInfo", ct, this);
        var installedModules = installTask.GetAwaiter().GetResult();

        WriteProgress(new ProgressRecord(1, "Install-ModuleFast", "Completed") { RecordType = ProgressRecordType.Completed });
        WriteVerbose("✅ All required modules installed! Exiting.");

        if (PassThru)
          foreach (var m in installedModules)
            WriteObject(m);

        if (CI)
        {
          WriteVerbose($"Writing lockfile to {CILockFilePath}");
          var lockFile = new Dictionary<string, string>();
          foreach (var m in finalInstallPlan)
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
      _cancelSource?.Dispose();
    }
  }
}