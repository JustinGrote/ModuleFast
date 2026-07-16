using System.Collections;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Reflection;

using Microsoft.PowerShell.Commands;

using NuGet.Versioning;

namespace ModuleFast;

/// <summary>
/// Represent a module either available in a package repository or installed locally. This is a lightweight representation of a module, and does not require loading the module into the current session.
/// </summary>
public sealed record ModuleFastInfo(string Name, NuGetVersion ModuleVersion, Uri Location)
{
  public ReadOnlyCollection<PSModuleInfo> RequiredModules { get; init; } = [];
  public Guid Guid { get; init; } = Guid.Empty;
  public bool IsLocal => Location.IsFile;
  public bool PreRelease => ModuleVersion.IsPrerelease || ModuleVersion.HasMetadata;

  public static implicit operator ModuleSpecification(ModuleFastInfo info) =>
    new(new Hashtable
    {
      { "ModuleName", info.Name },
      { "RequiredVersion", info.ModuleVersion.Version },
      { "Guid", info.Guid }
    });

  public override string ToString() => $"{Name}({ModuleVersion})";
}