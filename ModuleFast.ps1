#requires -version 7.2
# This is the bootstrap script for ModuleFast. It is used to load the module and do a simple invocation if arguments were specified.

$moduleUri = 'https://raw.githubusercontent.com/JustinGrote/ModuleFast/main/ModuleFast.psm1'
Write-Debug "Fetching Modulefast from $moduleUri"
$scriptblock = [ScriptBlock]::Create((Invoke-WebRequest $moduleUri))
New-Module -Name 'ModuleFast' -ScriptBlock $scriptblock | Out-Null

#If we were dot sourced with args, run install-modulefast with those args
if ($args.count) {
  Write-Debug "Detected we were started with args, running Install-ModuleFast $($args -join ' ')"
  Install-ModuleFast @args
}