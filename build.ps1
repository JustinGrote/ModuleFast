$ErrorActionPreference = 'Stop'

#Use the simple v1 for now for bootstrapping
$v0ModuleFastUri = 'https://github.com/JustinGrote/ModuleFast/releases/download/v0.6.1/ModuleFast.ps1'
& ([ScriptBlock]::Create((iwr $v0ModuleFastUri))) -path ./ModuleFastBuild.requires.psd1

Push-Location $PSScriptRoot
try {
  Invoke-Build @args
} finally {
  Pop-Location
}
