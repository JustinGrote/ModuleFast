using System.Management.Automation;
using System.Reflection;

namespace ModuleFast;

public enum InstallScope { CurrentUser, AllUsers }

public static class PathHelper
{
  public static string? GetPSDefaultModulePath(bool allUsers)
  {
    try
    {
      var scopeType = Type.GetType("System.Management.Automation.Configuration.ConfigScope, System.Management.Automation")
          ?? typeof(PSCmdlet).Assembly.GetType("System.Management.Automation.Configuration.ConfigScope");
      if (scopeType == null) return null;

      var pscType = scopeType.Assembly.GetType("System.Management.Automation.Configuration.PowerShellConfig");
      if (pscType == null) return null;

      var instance = pscType.GetField("Instance", BindingFlags.Static | BindingFlags.NonPublic)?.GetValue(null);
      if (instance == null) return null;

      var method = pscType.GetMethod("GetModulePath", BindingFlags.Instance | BindingFlags.NonPublic);
      if (method == null) return null;

      var scopeValue = allUsers
          ? Enum.Parse(scopeType, "AllUsers")
          : Enum.Parse(scopeType, "CurrentUser");

      return method.Invoke(instance, [scopeValue]) as string;
    }
    catch
    {
      return null;
    }
  }

  public static void AddDestinationToPSModulePath(string destination, bool noProfileUpdate, PSCmdlet cmdlet)
  {
    destination = Path.GetFullPath(destination);

    var modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
        .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);

    if (modulePaths.Contains(destination, StringComparer.OrdinalIgnoreCase))
    {
      cmdlet.WriteDebug($"Destination '{destination}' is already in PSModulePath.");
      return;
    }

    cmdlet.WriteVerbose($"Updating PSModulePath to include {destination}");
    Environment.SetEnvironmentVariable("PSModulePath",
        destination + Path.PathSeparator + Environment.GetEnvironmentVariable("PSModulePath"));

    if (noProfileUpdate)
    {
      cmdlet.WriteDebug("Skipping profile update because -NoProfileUpdate was specified.");
      return;
    }

    var myProfile = (string?)cmdlet.GetVariableValue("profile.CurrentUserAllHosts")
        ?? (string?)cmdlet.GetVariableValue("profile");
    if (string.IsNullOrEmpty(myProfile)) return;

    if (!File.Exists(myProfile))
    {
      if (!ApproveAction(myProfile, $"Allow ModuleFast to work by creating a profile at {myProfile}.", cmdlet))
        return;
      cmdlet.WriteVerbose("User All Hosts profile not found, creating one.");
      Directory.CreateDirectory(Path.GetDirectoryName(myProfile) ?? ".");
      File.WriteAllText(myProfile, "");
    }

    // Use relative destination if possible
    var displayDestination = destination;
    var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    foreach (var basePath in new[] { localAppData, home })
    {
      var rel = Path.GetRelativePath(basePath, destination);
      if (rel != destination)
      {
        displayDestination = "$([environment]::GetFolderPath('LocalApplicationData'))" +
            Path.DirectorySeparatorChar + rel;
        break;
      }
    }

    var profileLine = $"if (\"{displayDestination}\" -notin ($env:PSModulePath.split([IO.Path]::PathSeparator))) {{ $env:PSModulePath = \"{displayDestination}\" + $([IO.Path]::PathSeparator + $env:PSModulePath) }} #Added by ModuleFast.";

    var profileContent = File.ReadAllText(myProfile);
    if (!profileContent.Contains(profileLine))
    {
      if (!ApproveAction(myProfile, $"Allow ModuleFast to add {destination} to PSModulePath on startup.", cmdlet))
        return;
      cmdlet.WriteVerbose($"Adding {destination} to profile {myProfile}");
      File.AppendAllText(myProfile, "\n\n" + profileLine + "\n");
    }
    else
    {
      cmdlet.WriteVerbose($"PSModulePath {destination} already in profile, skipping...");
    }
  }

  public static bool ApproveAction(string target, string action, PSCmdlet cmdlet)
  {
    var message = $"Performing the operation \"{action}\" on target \"{target}\"";
    if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CI")))
    {
      cmdlet.WriteVerbose($"{message} (Auto-Confirmed because $ENV:CI is specified)");
      return true;
    }

    var confirmPrefObj = cmdlet.GetVariableValue("ConfirmPreference");
    if (confirmPrefObj?.ToString() == "None")
    {
      cmdlet.WriteVerbose($"{message} (Auto-Confirmed because ConfirmPreference is None)");
      return true;
    }

    return cmdlet.ShouldProcess(target, action);
  }
}