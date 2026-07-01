using Microsoft.PowerShell.Commands;

using NuGet.Versioning;

namespace ModuleFast;

/// <summary>
/// Information about a module, whether local or remote.
/// </summary>
public sealed record ModuleFastInfo(
  string Name,
  NuGetVersion ModuleVersion,
  Uri Location
)
{
  public bool IsLocal => Location.IsFile;
  public Guid Guid { get; init; } = Guid.Empty;

  public bool PreRelease => ModuleVersion.IsPrerelease || ModuleVersion.HasMetadata;

  public ModuleFastInfo(string name, string version, string location)
      : this(name, NuGetVersion.Parse(version), new Uri(location)) { }

  public static implicit operator ModuleSpecification(ModuleFastInfo info) =>
      new(new System.Collections.Hashtable
      {
        ["ModuleName"] = info.Name,
        ["RequiredVersion"] = info.ModuleVersion.Version
      });

  public override string ToString() => $"{Name}({ModuleVersion})";
}