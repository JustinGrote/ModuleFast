using namespace System.Net.Http
#requires -version 7.2
# This is the bootstrap script for Modules
[CmdletBinding(PositionalBinding = $false)]
param (
	#Specify a specific release to use, otherwise 'latest' is used
	[string]$Release = 'latest',
	#Specify the user
	[string]$User = 'JustinGrote',
	#Specify the repo
	[string]$Repo = 'ModuleFast',
	#Specify the module file
	[string]$ModuleFile = 'ModuleFast.psm1',
	#Entrypoint to be used if additional args are specified
	[string]$EntryPoint = 'Install-ModuleFast',
	#Specify the module name
	[string]$ModuleName = 'ModuleFast',
	#Path of the module to bootstrap. You normally won't change this but you can override it if you want
	[string]$Uri = $(
		$base = "https://github.com/$User/$Repo/releases/{0}/$ModuleFile";
		$version = $Release -eq 'latest' ? 'latest/download' : "download/$Release";
		$base -f $version
	),
	#All additional arguments passed to this script will be passed to Install-ModuleFast
	[Parameter(ValueFromRemainingArguments)]$installArgs
)
$ErrorActionPreference = 'Stop'

Write-Debug "Fetching $ModuleName from $Uri"
$ProgressPreference = 'SilentlyContinue'
try {
	$httpClient = [HttpClient]::new()
	$httpClient.DefaultRequestHeaders.AcceptEncoding.Add('gzip')
	$response = $httpClient.GetStringAsync($Uri).GetAwaiter().GetResult()
} catch {
	$PSItem.ErrorDetails = "Failed to fetch $ModuleName from $Uri`: $PSItem"
	$PSCmdlet.ThrowTerminatingError($PSItem)
}
Write-Debug 'Fetched response'
$scriptBlock = [ScriptBlock]::Create($response)
$ProgressPreference = 'Continue'

New-Module -Name $ModuleName -ScriptBlock $scriptblock | Out-Null
Write-Debug "Loaded Module $ModuleName"

if ($installArgs) {
	Write-Debug "Detected we were started with args, running $Entrypoint $($installArgs -join ' ')"
	& $EntryPoint @installArgs
}
