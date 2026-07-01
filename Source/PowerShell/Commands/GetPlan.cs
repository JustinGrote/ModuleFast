using System.Management.Automation;

namespace ModuleFast.Commands;

/// <remarks>
/// THIS COMMAND IS DEPRECATED AND WILL NOT RECEIVE PARAMETER UPDATES. Please use Install-ModuleFast -Plan instead.
/// </remarks>
[Cmdlet(VerbsCommon.Get, "ModuleFastPlan")]
[OutputType(typeof(ModuleFastInfo))]
public class GetModuleFastPlanCommand : TaskCmdlet
{
  [Parameter(Position = 0, Mandatory = true, ValueFromPipeline = true)]
  [Alias("Name")]
  public ModuleFastSpec[]? Specification { get; set; }

  [Parameter]
  public string Source { get; set; } = "https://pwsh.gallery/index.json";

  [Parameter]
  public SwitchParameter Prerelease { get; set; }

  [Parameter]
  public SwitchParameter Update { get; set; }

  [Parameter]
  public PSCredential? Credential { get; set; }

  [Parameter]
  public int Timeout { get; set; } = 30;

  [Parameter]
  public string? Destination { get; set; }

  [Parameter]
  public SwitchParameter DestinationOnly { get; set; }

  [Parameter]
  public SwitchParameter StrictSemVer { get; set; }

  private readonly HashSet<ModuleFastSpec> _specs = [];

  protected override async Task Process()
  {
    foreach (ModuleFastSpec spec in Specification ?? [])
      _specs.Add(spec);
  }

  protected override async Task End()
  {
    if (Update) ModuleFastCache.Instance.Clear();

    // Normalize source
    if (Uri.TryCreate(Source, UriKind.Absolute, out Uri? srcUri) &&
        srcUri.Scheme is not "http" and not "https")
    {
      Source = $"https://{Source}/index.json";
    }

    HttpClient httpClient = ModuleFastClient.Create(Credential?.GetNetworkCredential(), Timeout);
    var planner = new ModuleFastPlanner(httpClient, Source);

    string[] modulePaths;
    if (DestinationOnly && !string.IsNullOrEmpty(Destination))
    {
      modulePaths = [Destination];
    }
    else if (!string.IsNullOrEmpty(Destination))
    {
      var envPaths = Environment.GetEnvironmentVariable("PSModulePath")
          ?.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];
      modulePaths = [Destination, .. envPaths];
    }
    else
    {
      modulePaths = Environment.GetEnvironmentVariable("PSModulePath")
          ?.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries) ?? [];
    }

    try
    {
      HashSet<ModuleFastInfo> plan = await planner.GetPlan(
          _specs,
          modulePaths,
          Update,
          Prerelease,
          StrictSemVer,
          DestinationOnly,
          CancellationToken.None,
          new TaskCmdletInteractor(this)).ConfigureAwait(false);

      foreach (ModuleFastInfo info in plan)
        WriteObject(info);
    }
    catch (Exception ex) when (ex is not PipelineStoppedException)
    {
      ThrowTerminatingError(new ErrorRecord(ex, "GetModuleFastPlanFailed", ErrorCategory.NotSpecified, null));
    }
  }
}