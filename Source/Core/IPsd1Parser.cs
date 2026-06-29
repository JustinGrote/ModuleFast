using System.Collections;

namespace ModuleFast;

/// <summary>
/// Abstraction for parsing PowerShell module manifest (.psd1) files.
/// The Core library defines this contract; host projects provide implementations
/// (e.g. using System.Management.Automation.Language.Parser).
/// </summary>
public interface IPsd1Parser
{
  /// <summary>
  /// Parses a .psd1 file and returns its contents as a Hashtable.
  /// </summary>
  Hashtable ParseFile(string path);
}
