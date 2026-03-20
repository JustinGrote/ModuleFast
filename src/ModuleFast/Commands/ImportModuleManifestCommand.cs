using System.Collections;
using System.Management.Automation;

namespace ModuleFast.Commands;

/// <summary>
/// Imports a module manifest from a path, handling dynamic manifest formats.
/// NOTE: This cmdlet is primarily for internal use and testing.
/// </summary>
[Cmdlet(VerbsData.Import, "ModuleManifest")]
[OutputType(typeof(Hashtable))]
public class ImportModuleManifestCommand : PSCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string? Path { get; set; }

    protected override void ProcessRecord()
    {
        if (string.IsNullOrEmpty(Path))
        {
            ThrowTerminatingError(new ErrorRecord(
                new ArgumentNullException(nameof(Path)),
                "PathRequired",
                ErrorCategory.InvalidArgument,
                null));
            return;
        }

        try
        {
            var result = ModuleManifestReader.ImportModuleManifest(Path, this);
            WriteObject(result);
        }
        catch (Exception ex)
        {
            ThrowTerminatingError(new ErrorRecord(ex, "ImportModuleManifestFailed", ErrorCategory.ReadError, Path));
        }
    }
}
