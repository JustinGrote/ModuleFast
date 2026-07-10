$ErrorActionPreference = 'Stop'

#Run in a separate job to avoid keeping the legacy nuget versioning assembly in memory.
Start-Job {
  #Use the simple v1 for now for bootstrapping
  $v0ModuleFastUri = 'https://github.com/JustinGrote/ModuleFast/releases/download/v0.6.1/ModuleFast.ps1'
  iwr $v0ModuleFastUri | iex
  Install-ModuleFast
} | Receive-Job -Wait -AutoRemoveJob

Push-Location $PSScriptRoot
try {
  Invoke-Build @args
} finally {
  Pop-Location
}
