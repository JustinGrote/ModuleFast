namespace ModuleFast;

/// <summary>
/// Abstraction for host-specific interactions that require user confirmation
/// or access to host state. Used by PathHelper for profile management.
/// </summary>
public interface IHostInteraction
{
  /// <summary>Logger for writing messages to the host.</summary>
  IModuleFastLogger Logger { get; }

  /// <summary>Requests confirmation from the user for a potentially destructive action.</summary>
  bool Confirm(string target, string action);

  /// <summary>Gets a variable value from the host (e.g. $profile).</summary>
  object? GetVariable(string name);

  /// <summary>Gets the host name (e.g. "ConsoleHost", "Visual Studio Code Host").</summary>
  string? HostName { get; }
}
