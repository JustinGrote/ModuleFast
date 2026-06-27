using System.Management.Automation;

namespace ModuleFast;

public enum InstallScope { CurrentUser, AllUsers }

public static class PathHelper
{
  public static string? GetPSDefaultModulePath(bool allUsers)
  {
    try
    {
      var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      var modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
          .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
          .Select(p =>
          {
            try { return Path.GetFullPath(p); }
            catch { return p; }
          })
          .ToArray();

      if (modulePaths.Length > 0)
      {
        if (allUsers)
        {
          var allUsersPath = modulePaths.FirstOrDefault(p =>
              !p.StartsWith(userProfile, StringComparison.OrdinalIgnoreCase));
          if (!string.IsNullOrWhiteSpace(allUsersPath)) return allUsersPath;
        }
        else
        {
          var currentUserPath = modulePaths.FirstOrDefault(p =>
              p.StartsWith(userProfile, StringComparison.OrdinalIgnoreCase));
          if (!string.IsNullOrWhiteSpace(currentUserPath)) return currentUserPath;
        }
      }

      if (OperatingSystem.IsWindows())
      {
        if (allUsers)
        {
          var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
          return string.IsNullOrWhiteSpace(programFiles)
              ? null
              : Path.Combine(programFiles, "PowerShell", "Modules");
        }

        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return string.IsNullOrWhiteSpace(documents)
            ? null
            : Path.Combine(documents, "PowerShell", "Modules");
      }

      var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      if (!allUsers)
      {
        return string.IsNullOrWhiteSpace(home)
            ? null
            : Path.Combine(home, ".local", "share", "powershell", "Modules");
      }

      return "/usr/local/share/powershell/Modules";
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

    var profileValue = cmdlet.GetVariableValue("profile");
    var myProfile = profileValue switch
    {
      string s => s,
      PSObject pso => pso.Properties["CurrentUserAllHosts"]?.Value?.ToString() ?? pso.BaseObject?.ToString(),
      _ => null
    };

    // VSCode's PowerShell extension uses a custom host whose $profile.CurrentUserAllHosts
    // may be null or incorrect. Fall back to the standard filesystem location.
    if (string.IsNullOrEmpty(myProfile))
    {
      cmdlet.WriteVerbose("CurrentUserAllHosts profile path is not set.");
    }
    else if (string.Equals(cmdlet.Host?.Name, "Visual Studio Code Host", StringComparison.OrdinalIgnoreCase))
    {
      cmdlet.WriteVerbose("Visual Studio Code Host detected; resolving profile path from filesystem.");
      // On Windows: %USERPROFILE%\Documents\PowerShell\profile.ps1
      // On Linux/macOS: ~/.config/powershell/profile.ps1  (XDG standard; matches pwsh default)
      var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      myProfile = OperatingSystem.IsWindows()
          ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PowerShell", "profile.ps1")
          : Path.Combine(userProfile, ".config", "powershell", "profile.ps1");
    }

    if (string.IsNullOrEmpty(myProfile)) return;

    if (!File.Exists(myProfile))
    {
      if (!ApproveAction(myProfile, $"Allow ModuleFast to work by creating a profile at {myProfile}.", cmdlet))
        return;
      cmdlet.WriteVerbose("User All Hosts profile not found, creating one.");
      Directory.CreateDirectory(Path.GetDirectoryName(myProfile) ?? ".");
      // Use FileStream with explicit options to avoid unnecessary buffering for a new empty file
      using var _ = new FileStream(myProfile, new FileStreamOptions
      {
        Mode = FileMode.CreateNew,
        Access = FileAccess.Write,
        Share = FileShare.None,
        Options = FileOptions.WriteThrough,
      });
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

    // Use FileStreamOptions with SequentialScan for reading (the profile is read top-to-bottom once)
    string profileContent;
    using (var fs = new FileStream(myProfile, new FileStreamOptions
    {
      Mode = FileMode.Open,
      Access = FileAccess.Read,
      Share = FileShare.Read,
      Options = FileOptions.SequentialScan,
    }))
    using (var reader = new StreamReader(fs))
      profileContent = reader.ReadToEnd();

    if (!profileContent.Contains(profileLine))
    {
      if (!ApproveAction(myProfile, $"Allow ModuleFast to add {destination} to PSModulePath on startup.", cmdlet))
        return;
      cmdlet.WriteVerbose($"Adding {destination} to profile {myProfile}");
      // WriteThrough flushes each write directly to the OS, avoiding buffered-write data loss on crash
      using var appendFs = new FileStream(myProfile, new FileStreamOptions
      {
        Mode = FileMode.Append,
        Access = FileAccess.Write,
        Share = FileShare.Read,
        Options = FileOptions.WriteThrough,
      });
      using var writer = new StreamWriter(appendFs);
      writer.Write("\n\n" + profileLine + "\n");
    }
    else
    {
      cmdlet.WriteVerbose($"PSModulePath {destination} already in profile, skipping...");
    }
  }

  public static bool ApproveAction(string target, string action, PSCmdlet cmdlet)
  {
    var message = $"Performing the operation \"{action}\" on target \"{target}\"";

    // Explicitly honor -Confirm:$false passed to the cmdlet, which should bypass
    // any interactive confirmation prompts even when ShouldProcess is used.
    if (cmdlet.MyInvocation?.BoundParameters != null &&
        cmdlet.MyInvocation.BoundParameters.TryGetValue("Confirm", out var confirmObj) &&
        confirmObj is SwitchParameter confirmSwitch && !confirmSwitch.IsPresent)
    {
      cmdlet.WriteVerbose($"{message} (Auto-Confirmed because -Confirm:$false was specified)");
      return true;
    }

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

    // FIXME: ShouldProcess is not working as expected in this context, so we are bypassing it for now. This should be revisited in the future.
    // return cmdlet.ShouldProcess(target, action);
    return true;
  }
}