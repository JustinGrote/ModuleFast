#requires -version 7.2

# Load the C# binary module — probe Artifacts Output Layout paths first, then
# the classic deployed path (bin/ModuleFast/ModuleFast.dll).
$binaryModulePaths = @(
    if ($env:MODULEFASTDEBUG) {
        Write-Host -Fore Green "ModuleFast Debug Mode Enabled: Looking for binary module in Artifacts Output Layout"
        $buildTypes = 'debug', 'release'
        $artifactsDir = Join-Path $PSScriptRoot 'Artifacts'
        $buildDir = Join-Path $artifactsDir 'bin' 'PowerShell'
        $publishDir = Join-Path $artifactsDir 'publish' 'PowerShell'
        foreach ($buildType in $buildTypes) {
            # Build artifacts first
            (Join-Path $buildDir $buildType 'ModuleFast.dll')
            # Publish Artifacts Next
            (Join-Path $publishDir $buildType 'ModuleFast.dll')
        }
    }
    # Classic deployed layout in same folder
    (Join-Path $PSScriptRoot 'ModuleFast.dll')
    # Published Output as a debug fallback
    (Join-Path $PSScriptRoot 'Artifacts', 'Module', 'ModuleFast.dll')
)

$binaryModulePath = foreach ($path in $binaryModulePaths) {
    Write-Debug "Looking for binary module at path: $path"
    if (Test-Path $path) {
        Write-Debug "✅ Found binary module at path: $path"
        $path
        break
    }
}

if (-not $binaryModulePath) {
    throw "Binary module DLL not found in expected paths: $($binaryModulePaths -join ', '). This is probably a bug."
}

Write-Debug "Importing binary module from path: $binaryModulePath"
Import-Module $binaryModulePath -Force

# Register type accelerators so [ModuleFastSpec], [ModuleFastInfo], etc. work without namespace
# $accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
# foreach ($pair in @{
#         'ModuleFastSpec' = [ModuleFast.ModuleFastSpec]
#         'ModuleFastInfo' = [ModuleFast.ModuleFastInfo]
#         'SpecFileType'   = [ModuleFast.SpecFileType]
#         'InstallScope'   = [ModuleFast.InstallScope]
#     }.GetEnumerator()) {
#     if (-not $accelerators::Get.ContainsKey($pair.Key)) {
#         [void]$accelerators::Add($pair.Key, $pair.Value)
#     }
# }
# $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
#     $accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
#     'ModuleFastSpec', 'ModuleFastInfo', 'SpecFileType', 'InstallScope' | ForEach-Object {
#         [void]$accelerators::Remove($_)
#     }
# }

Set-Alias imf -Value Install-ModuleFast
