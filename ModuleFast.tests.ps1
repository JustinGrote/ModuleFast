using namespace System.Management.Automation
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

  #This is used for testcases
  $SCRIPT:moduleName = 'Az.Accounts'

  It 'Gets Module by <Test>' {
    $actual = Get-ModuleFastPlan $spec
    $actual | Should -HaveCount 1
    $actual.Name | Should -Be $spec
    $actual.ModuleVersion -as [NuGetVersion] | Should -Not -BeNullOrEmpty
  } -TestCases (
    @{Test = 'Name'; Spec = $moduleName },
		@{Test = 'MinimumVersion'; Spec = @{ ModuleName = $moduleName; ModuleVersion = '0.0.0' } },
		@{Test = 'RequiredVersionNotLatest'; Spec = @{ ModuleName = $moduleName; RequiredVersion = '2.7.3' } }
	)
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
			Import-PowerShellDataFile -Path $_.FullName | ForEach-Object ModuleVersion | Should -Be $moduleFolderVersion
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
