using System;
using System.Collections.Generic;
using System.Management.Automation;

using Microsoft.PowerShell.Commands;

using NuGet.Versioning;

namespace ModuleFast;

/// <summary>
/// Represents a module specification for ModuleFast, supporting NuGet version ranges and prerelease.
/// </summary>
public sealed class ModuleFastSpec : IComparable, IEquatable<ModuleFastSpec>
{
  private readonly string _name;
  private readonly Guid _guid;
  private readonly VersionRange _versionRange;
  private readonly bool _preReleaseName;

  // --- Properties ---

  public string Name => _name;
  public Guid Guid => _guid;
  public VersionRange VersionRange => _versionRange;

  public NuGetVersion? Min => _versionRange.MinVersion;
  public NuGetVersion? Max => _versionRange.MaxVersion;

  public NuGetVersion? Required =>
      Min != null && Max != null && Min == Max ? Min : null;

  public bool PreRelease =>
      (_versionRange.MinVersion?.IsPrerelease ?? false) ||
      (_versionRange.MaxVersion?.IsPrerelease ?? false) ||
      (_versionRange.MinVersion?.HasMetadata ?? false) ||
      (_versionRange.MaxVersion?.HasMetadata ?? false) ||
      _preReleaseName;

  // ModuleSpecification compatible helpers (used by op_Implicit)
  public Version? RequiredVersion => Required?.Version;
  public Version? Version => Min?.Version;
  public Version? MaximumVersion => Max?.Version;

  // --- Constructors ---

  public ModuleFastSpec(string name)
  {
    if (string.IsNullOrEmpty(name))
      throw new ArgumentException("Name is required", nameof(name));

    // Try ModuleSpecification hashtable-like string first
    if (ModuleSpecification.TryParse(name, out var moduleSpec))
    {
      (_name, _versionRange, _guid, _preReleaseName) = InitFromModuleSpec(moduleSpec!);
      return;
    }

    if (name.Contains("@{", StringComparison.Ordinal))
      throw new ArgumentException($"Cannot convert '{name}' to a ModuleFastSpec: not valid ModuleSpecification syntax.", nameof(name));

    // Prerelease flag
    bool preReleaseName = false;
    if (name.StartsWith('!') || name.EndsWith('!'))
    {
      preReleaseName = true;
      name = name.Trim('!');
    }

    string moduleName;
    VersionRange range;

    if (name.Contains(">=", StringComparison.Ordinal))
    {
      var parts = name.Split(">=", 2);
      moduleName = parts[0];
      range = NuGetVersion.TryParse(parts[1], out var lower)
          ? new VersionRange(lower, true)
          : throw new ArgumentException($"Invalid version '{parts[1]}'");
    }
    else if (name.Contains("<=", StringComparison.Ordinal))
    {
      var parts = name.Split("<=", 2);
      moduleName = parts[0];
      range = NuGetVersion.TryParse(parts[1], out var upper)
          ? new VersionRange(null, false, upper, true)
          : throw new ArgumentException($"Invalid version '{parts[1]}'");
    }
    else if (name.Contains('='))
    {
      var parts = name.Split('=', 2);
      moduleName = parts[0];
      range = VersionRange.Parse($"[{parts[1]}]");
    }
    else if (name.Contains(':'))
    {
      var parts = name.Split(':', 2);
      moduleName = parts[0];
      range = VersionRange.Parse(parts[1]);
    }
    else if (name.Contains('>'))
    {
      var parts = name.Split('>', 2);
      moduleName = parts[0];
      range = NuGetVersion.TryParse(parts[1], out var lowerExcl)
          ? new VersionRange(lowerExcl, false)
          : throw new ArgumentException($"Invalid version '{parts[1]}'");
    }
    else if (name.Contains('<'))
    {
      var parts = name.Split('<', 2);
      moduleName = parts[0];
      range = NuGetVersion.TryParse(parts[1], out var upperExcl)
          ? new VersionRange(null, false, upperExcl, false)
          : throw new ArgumentException($"Invalid version '{parts[1]}'");
    }
    else
    {
      moduleName = name;
      range = VersionRange.All;
    }

    _name = moduleName;
    _versionRange = range;
    _guid = System.Guid.Empty;
    _preReleaseName = preReleaseName;
  }

  public ModuleFastSpec(string name, string requiredVersion)
      : this(name, requiredVersion, System.Guid.Empty.ToString()) { }

  public ModuleFastSpec(string name, string requiredVersion, string guid)
  {
    if (string.IsNullOrEmpty(name)) throw new ArgumentException("Name is required", nameof(name));
    _name = name.Trim('!');
    _preReleaseName = name.StartsWith('!') || name.EndsWith('!');
    _versionRange = VersionRange.Parse($"[{requiredVersion}]");
    _guid = System.Guid.TryParse(guid, out var g) ? g : System.Guid.Empty;
  }

  public ModuleFastSpec(string name, VersionRange range)
  {
    if (string.IsNullOrEmpty(name)) throw new ArgumentException("Name is required", nameof(name));
    _name = name.Trim('!');
    _preReleaseName = name.StartsWith('!') || name.EndsWith('!');
    _versionRange = range ?? VersionRange.All;
    _guid = System.Guid.Empty;
  }

  public ModuleFastSpec(ModuleSpecification spec)
  {
    (_name, _versionRange, _guid, _preReleaseName) = InitFromModuleSpec(spec);
  }

  // --- Private helpers ---

  private static (string name, VersionRange range, Guid guid, bool preReleaseName)
      InitFromModuleSpec(ModuleSpecification spec)
  {
    string? minStr = spec.RequiredVersion?.ToString() ?? spec.Version?.ToString();
    string? maxStr = spec.RequiredVersion?.ToString() ?? spec.MaximumVersion?.ToString();

    var range = new VersionRange(
        string.IsNullOrEmpty(minStr) ? null : NuGetVersion.Parse(minStr),
        true,
        string.IsNullOrEmpty(maxStr) ? null : NuGetVersion.Parse(maxStr),
        true,
        null,
        $"ModuleSpecification: {spec}"
    );

    var guid = spec.Guid ?? System.Guid.Empty;
    return (spec.Name, range, guid, false);
  }

  // --- Methods ---

  public bool SatisfiedBy(System.Version version) =>
      SatisfiedBy(new NuGetVersion(version), false);

  public bool SatisfiedBy(NuGetVersion version) =>
      SatisfiedBy(version, false);

  /// <summary>
  /// Checks if this spec is satisfied by a given version.
  /// When strictSemVer=false (default), a prerelease of an exclusive upper bound is excluded.
  /// E.g. [1.0.0,2.0.0) will NOT match 2.0.0-alpha1 (non-strict), matching user expectation.
  /// </summary>
  public bool SatisfiedBy(NuGetVersion version, bool strictSemVer)
  {
    var range = _versionRange;
    bool strictSatisfies = range.IsFloating
        ? range.Float!.Satisfies(version)
        : range.Satisfies(version);

    if (strictSemVer)
      return strictSatisfies;

    if (range.MaxVersion == null)
      return strictSatisfies;

    var max = range.MaxVersion;
    var min = range.MinVersion;

    if (version.IsPrerelease &&
        !range.IsMaxInclusive &&
        !max.IsPrerelease &&
        max.Major == version.Major &&
        max.Minor == version.Minor &&
        max.Patch == version.Patch)
    {
      // Special case: (3.0.0-alpha,3.0.0-beta) — min and max share same M.m.p and min is prerelease
      if (min != null &&
          min.Major == max.Major &&
          min.Minor == max.Minor &&
          min.Patch == max.Patch &&
          min.IsPrerelease)
      {
        return strictSatisfies;
      }
      return false;
    }

    return strictSatisfies;
  }

  public bool Overlap(ModuleFastSpec other) => Overlap(other._versionRange);

  public bool Overlap(VersionRange other)
  {
    var subset = VersionRange.CommonSubSet(new List<VersionRange> { _versionRange, other });
    return !subset.Equals(VersionRange.None);
  }

  // --- Interface implementations ---

  public bool Equals(ModuleFastSpec? other) =>
      other != null && GetHashCode() == other.GetHashCode();

  public override bool Equals(object? obj) =>
      obj is ModuleFastSpec other && Equals(other);

  public override int GetHashCode() => ToString().GetHashCode();

  public int CompareTo(object? other)
  {
    if (Equals(other)) return 0;

    NuGetVersion? version;
    if (other is ModuleFastSpec otherSpec)
    {
      version = IsRequiredVersion(otherSpec._versionRange)
          ? otherSpec._versionRange.MaxVersion
          : throw new NotSupportedException($"ModuleFastSpec {other} has a version range, it must be a single required version e.g. '[1.5.0]'");
    }
    else if (other is VersionRange otherRange)
    {
      version = IsRequiredVersion(otherRange)
          ? otherRange.MaxVersion
          : throw new NotSupportedException($"ModuleFastSpec {other} has a version range, it must be a single required version e.g. '[1.5.0]'");
    }
    else
    {
      return ToString().CompareTo(other?.ToString());
    }

    if (_versionRange.Satisfies(version!)) return 0;
    if (_versionRange.MinVersion != null && _versionRange.MinVersion > version!) return 1;
    if (_versionRange.MaxVersion != null && _versionRange.MaxVersion < version!) return -1;
    throw new InvalidOperationException("Could not compare. This is a bug.");
  }

  private static bool IsRequiredVersion(VersionRange version) =>
      version.MinVersion == version.MaxVersion &&
      version.HasLowerAndUpperBounds &&
      version.IsMinInclusive &&
      version.IsMaxInclusive;

  public override string ToString()
  {
    string guid = _guid != System.Guid.Empty ? $" [{_guid}]" : "";
    string versionRange;
    if (_versionRange.ToString() == "(, )")
    {
      versionRange = "";
    }
    else if (_versionRange.MaxVersion != null && _versionRange.MaxVersion == _versionRange.MinVersion)
    {
      versionRange = $"({_versionRange.MinVersion})";
    }
    else
    {
      versionRange = $" {_versionRange}";
    }
    return $"{_name}{guid}{versionRange}";
  }

  // --- Implicit conversion ---

  public static implicit operator ModuleSpecification(ModuleFastSpec spec)
  {
    var props = new System.Collections.Hashtable
    {
      ["ModuleName"] = spec.Name
    };

    if (spec.Guid != System.Guid.Empty)
      props["Guid"] = spec.Guid;

    if (spec.Required != null)
    {
      props["RequiredVersion"] = spec.Required.Version;
    }
    else if (spec.Min != null || spec.Max != null)
    {
      if (spec.Min != null) props["ModuleVersion"] = spec.Min.Version;
      if (spec.Max != null) props["MaximumVersion"] = spec.Max.Version;
    }
    else
    {
      props["ModuleVersion"] = new System.Version(0, 0);
    }

    return new ModuleSpecification(props);
  }
}