$ErrorActionPreference = 'Stop'

#Run in a separate job to avoid keeping the legacy nuget versioning assembly in memory.
Start-Job {
  #Use the simple v1 for now for bootstrapping
  $v0ModuleFastUri = 'https://github.com/JustinGrote/ModuleFast/releases/download/v0.6.1/ModuleFast.ps1'
  iwr $v0ModuleFastUri | iex
  Install-ModuleFast -NoPSModulePathUpdate
} | Receive-Job -Wait -AutoRemoveJob

# HACK: There's a problem in CI with the modulepath on windows, will fix this later
if ($isWindows) {
  $mfPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'powershell/Modules'
  $env:PSModulePath = "$mfPath;$env:PSModulePath"
}

Push-Location $PSScriptRoot
try {
  Invoke-Build @args
} finally {
  Pop-Location
}
