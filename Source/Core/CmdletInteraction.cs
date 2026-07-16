namespace ModuleFast;

/// <summary>
/// Abstraction for interacting with the cmdlet, allows the implementation to support multiple threads.
/// </summary>
public interface CmdletInteraction
{
  /// <summary>Requests confirmation from the user for a potentially destructive action.</summary>
  Task<bool> Confirm(string target, string action);

  /// <summary>Gets a variable value from the host (e.g. $profile).</summary>
  object? GetVariable(string name);

  /// <summary>Gets the host name (e.g. "ConsoleHost", "Visual Studio Code Host").</summary>
  string? HostName { get; }

  /// <summary>Writes a debug message to the host.</summary>
  void Debug(string message);

  /// <summary>Writes a verbose message to the host.</summary>
  void Verbose(string message);

  /// <summary>Writes a warning message to the host.</summary>
  void Warning(string message);

  /// <summary>Writes an informational message to the host.</summary>
  void Info(string message, string[]? tags = null);
}