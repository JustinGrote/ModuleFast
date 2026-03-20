using System.Management.Automation;

namespace ModuleFast.Commands;

[Cmdlet(VerbsCommon.Get, "ModuleFastPlan")]
[OutputType(typeof(ModuleFastInfo))]
public class GetModuleFastPlanCommand : PSCmdlet
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

    protected override void ProcessRecord()
    {
        base.ProcessRecord();
    }
}
