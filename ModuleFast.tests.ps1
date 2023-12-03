using namespace System.Management.Automation
using namespace Microsoft.PowerShell.Commands
using namespace System.Collections.Generic
using namespace System.Diagnostics.CodeAnalysis
using namespace NuGet.Versioning

. $PSScriptRoot/ModuleFast.ps1 -ImportNuGetVersioning
Import-Module $PSScriptRoot/ModuleFast.psm1 -Force

BeforeAll {
  if ($env:MFURI) {
    $PSDefaultParameterValues['Get-ModuleFastPlan:Source'] = $env:MFURI
  }
}

InModuleScope 'ModuleFast' {
  Describe 'ModuleFastSpec' {
    Context 'Constructors' {
      It 'Getters' {
        $spec = [ModuleFastSpec]'Test'
        'Name', 'Guid', 'Min', 'Max', 'Required' | ForEach-Object {
          $spec.PSObject.Properties.name | Should -Contain $PSItem
        }
      }

      It 'Name' {
        $spec = [ModuleFastSpec]'Test'
        $spec.Name | Should -Be 'Test'
        $spec.Guid | Should -Be ([Guid]::Empty)
        $spec.Min | Should -BeNull
        $spec.Max | Should -BeNull
        $spec.Required | Should -BeNull
      }

      It 'Has non-settable properties' {
        $spec = [ModuleFastSpec]'Test'
        { $spec.Min = '1' } | Should -Throw
        { $spec.Max = '1' } | Should -Throw
        { $spec.Required = '1' } | Should -Throw
        { $spec.Name = 'fake' } | Should -Throw
        { $spec.Guid = New-Guid } | Should -Throw
      }

      It 'ModuleSpecification' {
        $in = [ModuleSpecification]@{
          ModuleName    = 'Test'
          ModuleVersion = '2.1.5'
        }
        $spec = [ModuleFastSpec]$in
        $spec.Name | Should -Be 'Test'
        $spec.Guid | Should -Be ([Guid]::Empty)
        $spec.Min | Should -Be '2.1.5'
        $spec.Max | Should -BeNull
        $spec.Required | Should -BeNull
      }
    }

    Context 'ModuleSpecification Conversion' {
      It 'Name' {
        $spec = [ModuleSpecification][ModuleFastSpec]'Test'
        $spec.Name | Should -Be 'Test'
        $spec.Version | Should -Be '0.0'
        $spec.RequiredVersion | Should -BeNull
        $spec.MaximumVersion | Should -BeNull
      }
      It 'RequiredVersion' {
        $spec = [ModuleSpecification][ModuleFastSpec]::new('Test', '1.2.3')
        $spec.Name | Should -Be 'Test'
        $spec.RequiredVersion | Should -Be '1.2.3.0'
        $spec.Version | Should -BeNull
        $spec.MaximumVersion | Should -BeNull
      }
    }
  }
}

Describe 'Get-ModuleFastPlan' -Tag 'E2E' {
  BeforeAll {
    $SCRIPT:__existingPSModulePath = $env:PSModulePath
    $env:PSModulePath = $testDrive

    $SCRIPT:__existingProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'


  }
  AfterAll {
    $env:PSModulePath = $SCRIPT:__existingPSModulePath
    $ProgressPreference = $SCRIPT:__existingProgressPreference
  }

  Context 'Parameter Binding' {
    #This is used for testcases
    $SCRIPT:moduleName = 'Az.Accounts'

    Context 'ModuleFastSpec' {
      $moduleSpecTestCases = (
        @{
          Test  = 'Name';
          Spec  = $SCRIPT:moduleName;
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Test  = 'ModuleSpecification Name';
          Spec  = [ModuleSpecification]::new($SCRIPT:moduleName);
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Test  = 'ModuleSpecification MinimumVersion';
          Spec  = [ModuleSpecification]::new(@{ ModuleName = $SCRIPT:moduleName; ModuleVersion = '0.0.0' })
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Test  = 'ModuleSpecification RequiredVersion';
          Spec  = [ModuleSpecification]::new(@{ ModuleName = $SCRIPT:moduleName; RequiredVersion = '2.7.3' })
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        },
        @{
          Test  = 'ModuleSpecification MaximumVersion';
          Spec  = [ModuleSpecification]::new(@{ ModuleName = $SCRIPT:moduleName; MaximumVersion = '2.7.3' })
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        }
      )

      It 'Gets Module with Parameter: <Test>' {
        $actual = Get-ModuleFastPlan $Spec
        $actual | Should -HaveCount 1
        $ModuleName | Should -Be $actual.Name
        $actual.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -Not -BeNullOrEmpty
        if ($Check) { . $Check }
      } -TestCases $moduleSpecTestCases

      It 'Gets Module with Pipeline: <Test>' {
        $actual = $Spec | Get-ModuleFastPlan
        $actual | Should -HaveCount 1
        $ModuleName | Should -Be $actual.Name
        $actual.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -Not -BeNullOrEmpty
        if ($Check) { . $Check }
      } -TestCases $moduleSpecTestCases
    }

    Context 'ModuleFastSpec String' {
      $stringTestCases = (
        @{
          Spec  = 'Az.Accounts'
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts@2.7.3'
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts>2.7.3'
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts<2.7.3'
          Check = {
            $actual.ModuleVersion | Should -BeLessThan '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts<=2.7.3'
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts>=2.7.3'
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts:2.7.3'
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3' -Because 'With NuGet syntax, a bare version is a minimum version, not a requiredversion'
          }
        },
        @{
          Spec  = 'Az.Accounts:[2.7.3]'
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        },
        @{
          Spec  = 'Az.Accounts:(,2.7.3)'
          Check = {
            $actual.ModuleVersion | Should -BeLessThan '2.7.3'
          }
        },
        @{
          Spec  = '@{ModuleName = ''Az.Accounts''; ModuleVersion = ''2.7.3''}'
          Check = {
            $actual.ModuleVersion | Should -BeGreaterThan '2.7.3'
          }
        },
        @{
          Spec  = '@{ModuleName = ''Az.Accounts''; RequiredVersion = ''2.7.3''}'
          Check = {
            $actual.ModuleVersion | Should -Be '2.7.3'
          }
        }
      )
      It 'Gets Module with String Parameter: <Spec>' {
        $actual = Get-ModuleFastPlan $Spec
        $actual | Should -HaveCount 1
        $ModuleName | Should -Be $actual.Name
        $actual.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -Not -BeNullOrEmpty
        if ($Check) { . $Check }
      } -TestCases $stringTestCases

      It 'Gets Module with String Pipeline: <Spec>' {
        $actual = $Spec | Get-ModuleFastPlan
        $actual | Should -HaveCount 1
        $ModuleName | Should -Be $actual.Name
        $actual.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -Not -BeNullOrEmpty
        if ($Check) { . $Check }
      } -TestCases $stringTestCases
    }

    Context 'ModuleFastSpec Combinations' {
      It 'Strings as Parameter' {
        $actual = Get-ModuleFastPlan 'Az.Accounts', 'Az.Compute', 'ImportExcel'
        $actual | Should -HaveCount 3
        $actual | ForEach-Object {
          $PSItem.Name | Should -BeIn 'Az.Accounts', 'Az.Compute', 'ImportExcel'
          $PSItem.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -BeGreaterThan '1.0'
        }
      }
      It 'Strings as Pipeline' {
        $actual = 'Az.Accounts', 'Az.Compute', 'ImportExcel' | Get-ModuleFastPlan
        $actual | Should -HaveCount 3
        $actual | ForEach-Object {
          $PSItem.Name | Should -BeIn 'Az.Accounts', 'Az.Compute', 'ImportExcel'
          $PSItem.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -BeGreaterThan '1.0'
        }
      }
      It 'ModuleSpecs as Parameter' {
        $actual = Get-ModuleFastPlan 'Az.Accounts', '@{ModuleName = "Az.Compute"; ModuleVersion = "1.0.0" }', ([ModuleSpecification]::new('ImportExcel'))
        $actual | Should -HaveCount 3
        $actual | ForEach-Object {
          $PSItem.Name | Should -BeIn 'Az.Accounts', 'Az.Compute', 'ImportExcel'
          $PSItem.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -BeGreaterThan '1.0'
        }
      }
      It 'ModuleSpecs as Pipeline' {
        $actual = 'Az.Accounts>1', '@{ModuleName = "Az.Compute"; ModuleVersion = "1.0.0" }', ([ModuleSpecification]::new('ImportExcel')) | Get-ModuleFastPlan
        $actual | Should -HaveCount 3
        $actual | ForEach-Object {
          $PSItem.Name | Should -BeIn 'Az.Accounts', 'Az.Compute', 'ImportExcel'
          $PSItem.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -BeGreaterThan '1.0'
        }
      }
    }
  }

  It 'Errors on Unsupported Object instead of Stringifying' {
    { Get-ModuleFastPlan [Tuple]::Create('Az.Accounts') -ErrorAction Stop }
    | Should -Throw '*Cannot process argument transformation on parameter*'
  }
  It 'Gets Module with 1 dependency' {
    Get-ModuleFastPlan 'Az.Compute' | Should -HaveCount 2
  }
  It 'Gets Module with lots of dependencies (Az)' {
    Get-ModuleFastPlan @{ModuleName = 'Az'; ModuleVersion = '11.0' } | Should -HaveCount 86
  }
  It 'Gets Module with 4 section version number and a 4 section version number dependency (VMware.VimAutomation.Common)' {
    Get-ModuleFastPlan 'VMware.VimAutomation.Common' | Should -HaveCount 2
  }
  It 'Gets multiple modules' {
    Get-ModuleFastPlan @{ModuleName = 'Az'; ModuleVersion = '11.0' }, @{ModuleName = 'VMWare.PowerCli'; ModuleVersion = '13.2' }
    | Should -HaveCount 168
  }

  It 'Casts to ModuleSpecification' {
    $actual = (Get-ModuleFastPlan 'Az.Accounts') -as [Microsoft.PowerShell.Commands.ModuleSpecification]
    $actual | Should -BeOfType [Microsoft.PowerShell.Commands.ModuleSpecification]
    $actual.Name | Should -Be 'Az.Accounts'
    $actual.RequiredVersion | Should -BeGreaterThan '2.7.3'
  }
}

Describe 'Install-ModuleFast' -Tag 'E2E' {
  BeforeAll {
    $SCRIPT:__existingPSModulePath = $env:PSModulePath
    filter Limit-ModulePath {
      param(
        [string]$path,

        [Parameter(ValueFromPipeline)]
        [Management.Automation.PSModuleInfo]$InputObject
      )
      if ($PSItem.Path.StartsWith($path)) {
        return $PSItem
      }
    }
  }
  BeforeEach {
    #Remove all PSModulePath to not affect existing environment
    $installTempPath = Join-Path $testdrive $(New-Guid)
    New-Item -ItemType Directory -Path $installTempPath -ErrorAction stop
    $env:PSModulePath = $installTempPath

    [SuppressMessageAttribute(
      <#Category#>'PSUseDeclaredVarsMoreThanAssignments',
      <#CheckId#>$null,
      Justification = 'PSScriptAnalyzer doesnt see the connection between beforeeach and Describe/It'
    )]
    $imfParams = @{
      Destination          = $installTempPath
      NoProfileUpdate      = $true
      NoPSModulePathUpdate = $true
      Confirm              = $false
    }
  }
  AfterAll {
    $env:PSModulePath = $SCRIPT:__existingPSModulePath
  }
  It 'Installs Module' {
    #HACK: The testdrive mount is not available in the threadjob runspaces so we need to translate it
    Install-ModuleFast @imfParams 'Az.Accounts'
    Get-Item $installTempPath\Az.Accounts\*\Az.Accounts.psd1 | Should -Not -BeNullOrEmpty
  }
  It '4 section version numbers (VMware.PowerCLI)' {
    Install-ModuleFast @imfParams 'VMware.VimAutomation.Common'
    Get-Item $installTempPath\VMware*\*\*.psd1 | ForEach-Object {
      $moduleFolderVersion = $_ | Split-Path | Split-Path -Leaf
      Import-PowerShellDataFile -Path $_.FullName | Select-Object -ExpandProperty ModuleVersion | Should -Be $moduleFolderVersion
    }
    Get-Module VMWare* -ListAvailable
		| Limit-ModulePath $installTempPath
		| Should -HaveCount 2
  }
  It 'lots of dependencies (Az)' {
    Install-ModuleFast @imfParams 'Az'
		(Get-Module Az* -ListAvailable).count | Should -BeGreaterThan 10
  }
  It 'specific requiredVersion' {
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.7.4' }
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Should -Be '2.7.4'
  }
  It 'specific requiredVersion when newer version is present' {
    Install-ModuleFast @imfParams 'Az.Accounts'
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.7.4' }
    $installedVersions = Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version

    $installedVersions | Should -HaveCount 2
    $installedVersions | Should -Contain '2.7.4'
  }
  It 'Installs when Maximumversion is lower than currently installed' {
    Install-ModuleFast @imfParams 'Az.Accounts'
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; MaximumVersion = '2.7.3' }
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Should -Contain '2.7.3'
  }
  It 'Only installs once when Update is specified and latest has not changed' {
    Install-ModuleFast @imfParams 'Az.Accounts' -Update
    #This will error if the file already exists
    Install-ModuleFast @imfParams 'Az.Accounts' -Update
  }

  It 'Updates only dependent module that requires update' {
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.10.2' }
    Install-ModuleFast @imfParams	@{ ModuleName = 'Az.Compute'; RequiredVersion = '5.0.0' }
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object Version -Descending
		| Select-Object -First 1
		| Should -Be '2.10.2'

    Install-ModuleFast @imfParams 'Az.Compute', 'Az.Accounts' #Should not update
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object Version -Descending
		| Select-Object -First 1
		| Should -Be '2.10.2'

    Install-ModuleFast @imfParams 'Az.Compute' -Update #Should disregard local install and update latest Az.Accounts
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object Version -Descending
		| Select-Object -First 1
		| Should -BeGreaterThan ([version]'2.10.2')

    Get-Module Az.Compute -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object Version -Descending
		| Select-Object -First 1
		| Should -BeGreaterThan ([version]'5.0.0')
  }
}
