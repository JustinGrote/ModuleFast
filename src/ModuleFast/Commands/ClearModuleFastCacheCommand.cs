using System.Management.Automation;

namespace ModuleFast.Commands;

[Cmdlet(VerbsCommon.Clear, "ModuleFastCache")]
public class ClearModuleFastCacheCommand : PSCmdlet
{
    protected override void ProcessRecord()
    {
        base.ProcessRecord();
    }
}
