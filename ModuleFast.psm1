#requires -version 7.2

# Load the C# binary module — probe Artifacts Output Layout paths first, then
# the classic deployed path (bin/ModuleFast/ModuleFast.dll).
$binaryModulePaths = @(
    if ($env:MODULEFASTDEBUG) {
        # Loaded from the root folder after publishing
        (Join-Path $PSScriptRoot 'Build' 'ModuleFast.dll')
        # Artifacts Output Layout: dotnet build (debug, default)
        (Join-Path $PSScriptRoot 'artifacts' 'bin' 'ModuleFast' 'debug' 'ModuleFast.dll')
        # Artifacts Output Layout: dotnet build -c Release
        (Join-Path $PSScriptRoot 'artifacts' 'bin' 'ModuleFast' 'release' 'ModuleFast.dll')
    }
    # Classic deployed layout in same folder
    (Join-Path $PSScriptRoot 'ModuleFast.dll')
)

$binaryModulePath = $BinaryModulePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $binaryModulePath) {
    Write-Warning "Binary module DLL not found in expected paths: $($binaryModulePaths -join ', '). This is probably a bug."
}

Write-Debug "Importing binary module from path: $binaryModulePath"
Import-Module $binaryModulePath -Force

# Register type accelerators so [ModuleFastSpec], [ModuleFastInfo], etc. work without namespace
$accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($pair in @{
        'ModuleFastSpec' = [ModuleFast.ModuleFastSpec]
        'ModuleFastInfo' = [ModuleFast.ModuleFastInfo]
        'SpecFileType'   = [ModuleFast.SpecFileType]
        'InstallScope'   = [ModuleFast.InstallScope]
    }.GetEnumerator()) {
    if (-not $accelerators::Get.ContainsKey($pair.Key)) {
        [void]$accelerators::Add($pair.Key, $pair.Value)
    }
}
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    $accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    'ModuleFastSpec', 'ModuleFastInfo', 'SpecFileType', 'InstallScope' | ForEach-Object {
        [void]$accelerators::Remove($_)
    }
}

Set-Alias imf -Value Install-ModuleFast
