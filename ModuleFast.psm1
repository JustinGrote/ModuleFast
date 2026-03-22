#requires -version 7.2

# Load the C# binary module — probe Artifacts Output Layout paths first, then
# the classic deployed path (bin/ModuleFast/ModuleFast.dll).
$binaryModulePath = @(
    # Classic deployed layout in same folder
    (Join-Path $PSScriptRoot 'ModuleFast.dll')
    # Artifacts Output Layout: dotnet build (debug, default)
    (Join-Path $PSScriptRoot 'artifacts' 'bin' 'ModuleFast' 'debug'   'ModuleFast.dll')
    # Artifacts Output Layout: dotnet build -c Release
    (Join-Path $PSScriptRoot 'artifacts' 'bin' 'ModuleFast' 'release' 'ModuleFast.dll')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $binaryModulePath) {
    Write-Warning "Binary module DLL not found in expected paths. The module will be imported without the binary component, which will likely cause it to not function. Expected paths were: 'artifacts/bin/ModuleFast/debug/ModuleFast.dll', 'artifacts/bin/ModuleFast/release/ModuleFast.dll', and 'bin/ModuleFast/ModuleFast.dll' relative to the module root."
}

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
        $accelerators::Add($pair.Key, $pair.Value)
    }
}
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    $accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    'ModuleFastSpec','ModuleFastInfo','SpecFileType','InstallScope' | ForEach-Object {
        $accelerators::Remove($_)
    }
}

Set-Alias imf -Value Install-ModuleFast
