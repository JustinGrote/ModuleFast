namespace ModuleFast;

/// <summary>
/// Abstraction for parsing #Requires statements from PowerShell script files (.ps1/.psm1).
/// </summary>
public interface IScriptRequiresParser
{
  /// <summary>
  /// Parses a script file and returns the required module specifications from #Requires -Module statements.
  /// </summary>
  ModuleFastSpec[] ParseRequiredModules(string scriptPath);
}
