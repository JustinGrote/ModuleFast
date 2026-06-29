namespace ModuleFast;

/// <summary>
/// Abstraction for logging messages from Core library code.
/// Implemented by host-specific projects (PowerShell cmdlet, Console, etc.).
/// </summary>
public interface IModuleFastLogger
{
  void Verbose(string message);
  void Debug(string message);
  void Warning(string message);
}
