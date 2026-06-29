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

  public static async Task AddDestinationToPSModulePath(string destination, bool noProfileUpdate, CmdletInteraction cmdlet)
  {
    destination = Path.GetFullPath(destination);

    var modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
        .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);

    if (modulePaths.Contains(destination, StringComparer.OrdinalIgnoreCase))
    {
      cmdlet.Debug($"Destination '{destination}' is already in PSModulePath.");
      return;
    }

    cmdlet.Verbose($"Updating PSModulePath to include {destination}");
    Environment.SetEnvironmentVariable("PSModulePath",
        destination + Path.PathSeparator + Environment.GetEnvironmentVariable("PSModulePath"));

    if (noProfileUpdate)
    {
      cmdlet.Debug("Skipping profile update because -NoProfileUpdate was specified.");
      return;
    }

    var profileValue = cmdlet.GetVariable("profile");
    string? myProfile = profileValue?.ToString();

    // VSCode's PowerShell extension uses a custom host whose $profile.CurrentUserAllHosts
    // may be null or incorrect. Fall back to the standard filesystem location.
    if (string.IsNullOrEmpty(myProfile))
    {
      cmdlet.Verbose("CurrentUserAllHosts profile path is not set.");
    }
    else if (string.Equals(cmdlet.HostName, "Visual Studio Code Host", StringComparison.OrdinalIgnoreCase))
    {
      cmdlet.Verbose("Visual Studio Code Host detected; resolving profile path from filesystem.");
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
      if (!await cmdlet.Confirm(myProfile, $"Allow ModuleFast to work by creating a profile at {myProfile}."))
        return;

      cmdlet.Verbose("User All Hosts profile not found, creating one.");
      Directory.CreateDirectory(Path.GetDirectoryName(myProfile) ?? ".");
      // Use FileStream with explicit options to avoid unnecessary buffering for a new empty file
      using FileStream _ = new FileStream(myProfile, new FileStreamOptions
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
    using (FileStream fs = new FileStream(myProfile, new FileStreamOptions
    {
      Mode = FileMode.Open,
      Access = FileAccess.Read,
      Share = FileShare.Read,
      Options = FileOptions.SequentialScan,
    }))
    using (StreamReader reader = new StreamReader(fs))
      profileContent = reader.ReadToEnd();

    if (!profileContent.Contains(profileLine))
    {
      if (!await cmdlet.Confirm(
        myProfile,
        $"Allow ModuleFast to add {destination} to PSModulePath on startup."
      )) return;

      cmdlet.Verbose($"Adding {destination} to profile {myProfile}");
      // WriteThrough flushes each write directly to the OS, avoiding buffered-write data loss on crash
      using FileStream appendFs = new FileStream(myProfile, new FileStreamOptions
      {
        Mode = FileMode.Append,
        Access = FileAccess.Write,
        Share = FileShare.Read,
        Options = FileOptions.WriteThrough,
      });
      using StreamWriter writer = new StreamWriter(appendFs);
      writer.Write("\n\n" + profileLine + "\n");
    }
    else
    {
      cmdlet.Verbose($"PSModulePath {destination} already in profile, skipping...");
    }
  }
}