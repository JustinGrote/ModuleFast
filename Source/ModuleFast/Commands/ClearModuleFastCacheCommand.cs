using System.Management.Automation;

namespace ModuleFast.Commands;

[Cmdlet(VerbsCommon.Clear, "ModuleFastCache")]
public class ClearModuleFastCacheCommand : PSCmdlet
{
  protected override void ProcessRecord()
  {
    WriteDebug("Flushing ModuleFast Request Cache");
    ModuleFastCache.Instance.Clear();
  }
}