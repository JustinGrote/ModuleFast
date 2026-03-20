using System;
using System.Management.Automation;
using Microsoft.PowerShell.Commands;
using NuGet.Versioning;

namespace ModuleFast;

/// <summary>
/// Information about a module, whether local or remote.
/// </summary>
public sealed class ModuleFastInfo : IComparable
{
    public string Name { get; }
    public NuGetVersion ModuleVersion { get; }
    public Uri Location { get; }
    public bool IsLocal { get; }
    public Guid Guid { get; }

    public bool PreRelease => ModuleVersion.IsPrerelease || ModuleVersion.HasMetadata;

    public ModuleFastInfo(string name, NuGetVersion version, Uri location)
    {
        Name = name;
        ModuleVersion = version;
        Location = location;
        IsLocal = location.IsFile;
        Guid = Guid.Empty;
    }

    public static implicit operator ModuleSpecification(ModuleFastInfo info) =>
        new(new System.Collections.Hashtable
        {
            ["ModuleName"] = info.Name,
            ["RequiredVersion"] = info.ModuleVersion.Version
        });

    public override string ToString() => $"{Name}({ModuleVersion})";

    public string ToUniqueString() => $"{Name}-{ModuleVersion}-{Location}";

    public override int GetHashCode() => ToUniqueString().GetHashCode();

    public override bool Equals(object? obj) =>
        obj is ModuleFastInfo other && GetHashCode() == other.GetHashCode();

    public int CompareTo(object? other)
    {
        if (other is not ModuleFastInfo otherInfo)
            return ToUniqueString().CompareTo(other?.ToString());

        if (Equals(otherInfo)) return 0;
        if (Name != otherInfo.Name) return string.Compare(Name, otherInfo.Name, StringComparison.Ordinal);
        return ModuleVersion.CompareTo(otherInfo.ModuleVersion);
    }
}
