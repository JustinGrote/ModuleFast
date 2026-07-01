#requires -version 7.6
[CmdletBinding(ConfirmImpact = 'High')]
param(
  #Specify this to explicitly specify the version of the package
  [Management.Automation.SemanticVersion]$Version = '0.0.0-SOURCE',
  #You Generally do not need to modify these
  $Destination = (Join-Path $PSScriptRoot 'Artifacts'),
  $ModuleOutFolderPath = (Join-Path $Destination 'Module'),
  $TempPath = (Resolve-Path temp:).ProviderPath + '\ModuleFastBuild',
  # Build for release (don't include debug headers)
  [switch]$Release
)

$ErrorActionPreference = 'Stop'

$buildMode = $Release ? 'release' : 'debug'

# Short for common Parameters, we are using a short name here to keep the commands short
$c = @{
  ErrorAction = 'Stop'
  Verbose     = $VerbosePreference -eq 'Continue'
  Debug       = $DebugPreference -eq 'Continue'
}
if ($DebugPreference -eq 'Continue') {
  $c.Confirm = $false
}

Task Clean {
  Write-Build -Color DarkCyan "Cleaning $Destination"
  & git clean -fdX $Destination
}

Task BuildCSharp {
  # Build the PowerShell module project (which depends on Core)
  $csprojPath = Join-Path $PSScriptRoot 'Source' 'PowerShell' 'PowerShell.csproj'
  dotnet build $csprojPath --nologo -c $buildMode
}

Task CopyFiles {
  New-Item -ItemType Directory -Path $ModuleOutFolderPath -Force | Out-Null
  Copy-Item @c -Path @(
    'ModuleFast.psd1'
    'ModuleFast.psm1'
    'LICENSE'
  ) -Destination $ModuleOutFolderPath
  Copy-Item @c -Path 'ModuleFast.ps1' -Destination $Destination

  # Copy DLL and its dependencies from Artifacts Output to the module bin folder
  $artifactsBinPath = Join-Path $Destination 'publish' 'PowerShell' $buildMode
  Copy-Item @c -Path (Join-Path $artifactsBinPath '*') -Destination $ModuleOutFolderPath -Recurse -Force
}

Task Version {
  #This task only runs if a custom version is needed
  if (-not $Version) { return }

  $moduleVersion, $prerelease = $Version -split '-'
  $manifestPath = Join-Path $ModuleOutFolderPath 'ModuleFast.psd1'
  $manifestContent = (Get-Content -Raw $manifestPath) -replace [regex]::Escape('ModuleVersion     = ''0.0.0'''), "ModuleVersion     = '$moduleVersion'" -replace [regex]::Escape('Prerelease = ''SOURCE'''), ($Prerelease ? "Prerelease = '$prerelease'" : '')
  $manifestContent | Set-Content -Path $manifestPath
}

Task Publish {
  & dotnet publish (Join-Path $PSScriptRoot 'Source' 'PowerShell' 'PowerShell.csproj') -c $buildMode
}

Task Package.Nuget {
  Compress-PSResource @c -Path $ModuleOutFolderPath -DestinationPath $Destination
}

Task Package.Zip {
  $zipPath = Join-Path $Destination "ModuleFast.${Version}.zip"
  if (Test-Path $zipPath) {
    Remove-Item @c -Path $zipPath
  }
  Compress-Archive @c -Path $ModuleOutFolderPath -DestinationPath $zipPath
}

Task Pester {
  #Run this in a separate job so as not to lock any NuGet DLL packages for future runs. Runspace would lock the package to this process still.
  Start-Job {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-Pester -Configuration @{
      Run = @{
        PassThru = 'true'
      }
    }
  } | Receive-Job -Wait -AutoRemoveJob
}

Task Package Package.Nuget, Package.Zip

#Supported High Level Tasks
Task Build @(
  'Publish'
  'CopyFiles'
  'Version'
)

Task Test Build, Pester
Task . Build, Test, Package
Task BuildNoTest Build, Package
