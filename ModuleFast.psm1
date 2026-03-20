#requires -version 7.2

# Load the C# binary module (built output)
$binaryModulePath = Join-Path $PSScriptRoot 'bin' 'ModuleFast' 'ModuleFast.dll'
if (Test-Path $binaryModulePath) {
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
}

Set-Alias imf -Value Install-ModuleFast
