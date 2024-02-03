[CmdletBinding(ConfirmImpact = 'High')]
param(
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

Task Package {
  [string]$repoName = "ModuleFastBuild-" + (New-Guid)
  Get-ChildItem $ModuleOutFolderPath -Recurse -Include '*.nupkg' | Remove-Item @c -Force
  try {
    Register-PSResourceRepository -Name $repoName -Uri $NugetOutFolderPath -ApiVersion local
    Publish-PSResource -Repository $repoName -Path $ModuleOutFolderPath
  } finally {
    Unregister-PSResourceRepository -Name $repoName
  }
}

Task . Build, Test, Package
Task BuildNoTest Build, Package
