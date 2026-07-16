namespace ModuleFast;

public enum InstallScope { CurrentUser, AllUsers }

public static class PathHelper
{
  public static string? GetPSDefaultModulePath(bool allUsers)
  {
    try
    {
      string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      string[] modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
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
          string? allUsersPath = modulePaths.FirstOrDefault(p =>
              !p.StartsWith(userProfile, StringComparison.OrdinalIgnoreCase));
          if (!string.IsNullOrWhiteSpace(allUsersPath)) return allUsersPath;
        }
        else
        {
          string? currentUserPath = modulePaths.FirstOrDefault(p =>
              p.StartsWith(userProfile, StringComparison.OrdinalIgnoreCase));
          if (!string.IsNullOrWhiteSpace(currentUserPath)) return currentUserPath;
        }
      }

      if (OperatingSystem.IsWindows())
      {
        if (allUsers)
        {
          string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
          return string.IsNullOrWhiteSpace(programFiles)
              ? null
              : Path.Combine(programFiles, "PowerShell", "Modules");
        }

        string documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return string.IsNullOrWhiteSpace(documents)
            ? null
            : Path.Combine(documents, "PowerShell", "Modules");
      }

      string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
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
    static string GetDefaultProfilePath()
    {
      string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      return OperatingSystem.IsWindows()
          ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PowerShell", "profile.ps1")
          : Path.Combine(userProfile, ".config", "powershell", "profile.ps1");
    }

    destination = Path.GetFullPath(destination);

    string[] modulePaths = (Environment.GetEnvironmentVariable("PSModulePath") ?? "")
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

    object? profileValue = cmdlet.GetVariable("profile");
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
      myProfile = GetDefaultProfilePath();
    }

    if (string.IsNullOrEmpty(myProfile)) return;

    if (!Path.IsPathRooted(myProfile) || string.IsNullOrWhiteSpace(Path.GetDirectoryName(myProfile)))
    {
      cmdlet.Verbose($"Profile path '{myProfile}' is not fully qualified; resolving profile path from filesystem.");
      myProfile = GetDefaultProfilePath();
    }

    if (!File.Exists(myProfile))
    {
      if (!await cmdlet.Confirm(myProfile, $"Allow ModuleFast to work by creating a profile at {myProfile}.").ConfigureAwait(false))
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
    string displayDestination = destination;
    string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    foreach (string? basePath in new[] { localAppData, home })
    {
      if (string.IsNullOrWhiteSpace(basePath)) continue;
      string rel = Path.GetRelativePath(basePath, destination);
      if (rel != destination)
      {
        displayDestination = "$([environment]::GetFolderPath('LocalApplicationData'))" +
            Path.DirectorySeparatorChar + rel;
        break;
      }
    }

    string profileLine = $"if (\"{displayDestination}\" -notin ($env:PSModulePath.split([IO.Path]::PathSeparator))) {{ $env:PSModulePath = \"{displayDestination}\" + $([IO.Path]::PathSeparator + $env:PSModulePath) }} #Added by ModuleFast.";

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
      ).ConfigureAwait(false)) return;

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