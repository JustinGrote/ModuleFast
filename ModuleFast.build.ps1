#requires -version 7.2
[CmdletBinding(ConfirmImpact = 'High')]
param(
  #Specify this to explicitly specify the version of the package
  [Management.Automation.SemanticVersion]$Version = '0.0.0-SOURCE',
  #You Generally do not need to modify these
  $Destination = (Join-Path $PSScriptRoot 'Build'),
  $ModuleOutFolderPath = (Join-Path $Destination 'ModuleFast'),
  $TempPath = (Resolve-Path temp:).ProviderPath + '\ModuleFastBuild',
  $LibPath = (Join-Path $ModuleOutFolderPath 'lib' 'netstandard2.0'),
  $NugetVersioning = '6.8.0',
  $NugetOutFolderPath = $Destination
)

$ErrorActionPreference = 'Stop'

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
  foreach ($Path in $Destination, $NugetOutFolderPath, $ModuleOutFolderPath, $TempPath, $LibPath) {
    if (Test-Path $Path) {
      Remove-Item @c -Recurse -Force -Path $Path/*
    } else {
      New-Item @c -Type Directory -Path $Path | Out-Null
    }
  }
}

Task CopyFiles {
  Copy-Item @c -Path @(
    'ModuleFast.psd1'
    'ModuleFast.psm1'
    'LICENSE'
  ) -Destination $ModuleOutFolderPath
  Copy-Item @c -Path 'ModuleFast.ps1' -Destination $Destination
}

Task Version {
  #This task only runs if a custom version is needed
  if (-not $Version) { return }

  $moduleVersion, $prerelease = $Version -split '-'
  $manifestPath = Join-Path $ModuleOutFolderPath 'ModuleFast.psd1'
  $manifestContent = (Get-Content -Raw $manifestPath) -replace [regex]::Escape('ModuleVersion     = ''0.0.0'''), "ModuleVersion     = '$moduleVersion'" -replace [regex]::Escape('Prerelease = ''SOURCE'''), ($Prerelease ? "Prerelease = '$prerelease'" : '')
  $manifestContent | Set-Content -Path $manifestPath
}

Task GetNugetVersioningAssembly {
  Install-Package @c -Name Nuget.Versioning -RequiredVersion $NuGetVersioning -Destination $tempPath -Force | Out-Null
  Copy-Item @c -Path "$tempPath/NuGet.Versioning.$NuGetVersioning/lib/netstandard2.0/NuGet.Versioning.dll" -Destination $libPath -Recurse -Force
}

Task AddNugetVersioningAssemblyRequired {
  (Get-Content -Raw -Path $ModuleOutFolderPath\ModuleFast.psd1) -replace [Regex]::Escape('# RequiredAssemblies = @()'), 'RequiredAssemblies = @(".\lib\netstandard2.0\NuGet.Versioning.dll")' | Set-Content -Path $ModuleOutFolderPath\ModuleFast.psd1
}

Task Test {
  #Run this in a separate job so as not to lock any NuGet DLL packages for future runs. Runspace would lock the package to this process still.
  Start-Job {
    Invoke-Pester
  } | Receive-Job -Wait -AutoRemoveJob
}

Task Build @(
  'Clean'
  'CopyFiles'
  'GetNugetVersioningAssembly'
  'AddNugetVersioningAssemblyRequired'
)

Task Package.Nuget {
  [string]$repoName = 'ModuleFastBuild-' + (New-Guid)
  Get-ChildItem $ModuleOutFolderPath -Recurse -Include '*.nupkg' | Remove-Item @c -Force
  try {
    Register-PSResourceRepository -Name $repoName -Uri $NugetOutFolderPath -ApiVersion local
    Publish-PSResource -Repository $repoName -Path $ModuleOutFolderPath
  } finally {
    Unregister-PSResourceRepository -Name $repoName
  }
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
    Invoke-Pester
  } | Receive-Job -Wait -AutoRemoveJob
}

Task Package Package.Nuget, Package.Zip

#Supported High Level Tasks
Task Build @(
  'Clean'
  'CopyFiles'
  'Version'
  'GetNugetVersioningAssembly'
  'AddNugetVersioningAssemblyRequired'
)

Task Test Build, Pester
Task . Build, Test, Package
Task BuildNoTest Build, Package
