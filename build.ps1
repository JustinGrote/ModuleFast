$ErrorActionPreference = 'Stop'

#Use the local copy rather than the bootstrap to speed things up
. $PSScriptRoot/ModuleFast.ps1 -ImportNugetVersioning
$module = Import-Module $PSScriptRoot/ModuleFast.psd1 -Force -PassThru
Install-ModuleFast
Remove-Module $module
Push-Location $PSScriptRoot
try {
  Invoke-Build @args
} finally {
  Pop-Location
}
