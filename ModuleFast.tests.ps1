using namespace System.Management.Automation
using namespace Microsoft.PowerShell.Commands
using namespace System.Collections.Generic
using namespace System.Diagnostics.CodeAnalysis
using namespace NuGet.Versioning

. $PSScriptRoot/ModuleFast.ps1 -ImportNuGetVersioning
Import-Module $PSScriptRoot/ModuleFast.psm1 -Force

BeforeAll {
  if ($env:MFURI) {
    $PSDefaultParameterValues['*-ModuleFast*:Source'] = $env:MFURI
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

  Describe 'Import-ModuleManifest' {
    It 'Reads Dynamic Manifest' {
      $Mocks = "$PSScriptRoot/Test/Mocks"
      $manifest = Import-ModuleManifest "$Mocks/Dynamic.psd1"
      $manifest | Should -BeOfType [System.Collections.Hashtable]
      $manifest.ModuleVersion | Should -Be '1.0.0'
      $manifest.RootModule | Should -Be 'coreclr\PrtgAPI.PowerShell.dll'
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
          Spec  = 'Az.Accounts=2.7.3'
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
        },
        @{
          Spec       = 'PrereleaseTest'
          Check      = {
            $actual.Name | Should -Be 'PrereleaseTest'
            $actual.ModuleVersion | Should -Be '0.0.1'
          }
          ModuleName = 'PrereleaseTest'
        },
        @{
          Spec       = 'PrereleaseTest!'
          Check      = {
            $actual.Name | Should -Be 'PrereleaseTest'
            $actual.ModuleVersion | Should -Be '0.0.2-prerelease'
          }
          ModuleName = 'PrereleaseTest'
        },
        @{
          Spec       = '!PrereleaseTest'
          Check      = {
            $actual.Name | Should -Be 'PrereleaseTest'
            $actual.ModuleVersion | Should -Be '0.0.2-prerelease'
          }
          ModuleName = 'PrereleaseTest'
        },
        @{
          Spec       = 'PrereleaseTest!<0.0.1'
          Check      = {
            $actual.Name | Should -Be 'PrereleaseTest'
            $actual.ModuleVersion | Should -Be '0.0.1-prerelease'
          }
          ModuleName = 'PrereleaseTest'
        },
        @{
          Spec       = 'PrereleaseTest:*'
          ModuleName = 'PrereleaseTest'
        },
        @{
          Spec       = 'PnP.PowerShell:2.2.*'
          ModuleName = 'PnP.PowerShell'
          Check      = {
            $actual.ModuleVersion | Should -Be '2.2.0'
          }
        }
      )

      It 'Fails if hashtable-style string parameter is not a modulespec' {
        { Get-ModuleFastPlan '@{ModuleName = ''Az.Accounts''; ModuleVersion = ''2.7.3''; InvalidParameter = ''ThisShouldNotBeValid''}' -ErrorAction Stop }
        | Should -Throw '*Cannot process argument transformation on parameter*'
      }

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

      It 'Prerelease does not affect non-prerelease' {
        #The prerelease flag on az.accounts should not trigger prerelease on PrereleaseTest
        $actual = 'Az.Accounts!', 'PrereleaseTest' | Get-ModuleFastPlan
        $actual | Should -HaveCount 2
        $actual | Where-Object Name -EQ 'PrereleaseTest' | ForEach-Object {
          $PSItem.ModuleVersion | Should -Be '0.0.1'
        }
      }
      It '-Prerelease overrides even if prerelease is not specified' {
        #The prerelease flag on az.accounts should not trigger prerelease on PrereleaseTest
        $actual = 'Az.Accounts!', 'PrereleaseTest' | Get-ModuleFastPlan -PreRelease
        $actual | Should -HaveCount 2
        $actual | Where-Object Name -EQ 'PrereleaseTest' | ForEach-Object {
          $PSItem.ModuleVersion | Should -Be '0.0.2-prerelease'
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

  It 'Filters Prerelease Modules by Default' {
    $actual = Get-ModuleFastPlan 'PrereleaseTest'
    $actual.ModuleVersion | Should -Be '0.0.1'
  }
  It 'Shows Prerelease Modules if Prerelease is specified' {
    $actual = Get-ModuleFastPlan 'PrereleaseTest' -PreRelease
    $actual.ModuleVersion | Should -Be '0.0.2-prerelease'
  }
  It 'Detects Prerelease even if Prerelease not specified' {
    $actual = Get-ModuleFastPlan 'PrereleaseTest=0.0.2-prerelease'
    $actual.ModuleVersion | Should -Be '0.0.2-prerelease'
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
    $actual = Install-ModuleFast @imfParams 'VMware.VimAutomation.Common=13.2.0.22643733' -PassThru
    Get-Item $installTempPath\VMware*\*\*.psd1 | ForEach-Object {
      $moduleFolderVersion = $_ | Split-Path | Split-Path -Leaf
      Import-PowerShellDataFile -Path $_.FullName | Select-Object -ExpandProperty ModuleVersion | Should -Be $moduleFolderVersion
    }
    Get-Module VMWare* -ListAvailable
		| Limit-ModulePath $installTempPath
		| Should -HaveCount 2
  }
  It '4 section version numbers with repeated zeroes' {
    $actual = Install-ModuleFast @imfParams 'xDSCResourceDesigner=1.13.0.0' -PassThru
    $resolvedPath = Resolve-Path $actual.Location.LocalPath
    Split-Path $resolvedPath -Leaf | Should -Be '1.13.0.0'
    Get-Module xDSCResourceDesigner -ListAvailable
		| Limit-ModulePath $installTempPath
		| Should -HaveCount 1
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
    Install-ModuleFast @imfParams 'Az.Accounts' -Update -Debug *>&1
    | Select-String 'best remote candidate matches what is locally installed'
    | Should -Not -BeNullOrEmpty
  }
  It 'Only installs once when Update is specified and latest has not changed for multiple modules' {
    Install-ModuleFast @imfParams 'Az.Compute', 'Az.CosmosDB' -Update
    Install-ModuleFast @imfParams 'Az.Compute', 'Az.CosmosDB' -Update -Plan
    | Should -BeNullOrEmpty
  }

  It 'Updates if multiple local versions installed' {
    Install-ModuleFast @imfParams 'Plaster=1.1.1'
    Install-ModuleFast @imfParams 'Plaster=1.1.3'
    $actual = Install-ModuleFast @imfParams 'Plaster' -Update -PassThru
    $actual.ModuleVersion | Should -Be '1.1.4'
  }

  It 'Updates only dependent module that requires update' {
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.10.2' }
    Install-ModuleFast @imfParams	@{ ModuleName = 'Az.Compute'; RequiredVersion = '5.0.0' }
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object -Descending
		| Select-Object -First 1
		| Should -Be '2.10.2'

    Install-ModuleFast @imfParams 'Az.Compute', 'Az.Accounts' #Should not update
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object -Descending
		| Select-Object -First 1
		| Should -Be '2.10.2'

    Install-ModuleFast @imfParams 'Az.Compute' -Update #Should disregard local install and update latest Az.Accounts
    Get-Module Az.Accounts -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object -Descending
		| Select-Object -First 1
		| Should -BeGreaterThan ([version]'2.10.2')

    Get-Module Az.Compute -ListAvailable
		| Limit-ModulePath $installTempPath
		| Select-Object -ExpandProperty Version
		| Sort-Object -Descending
		| Select-Object -First 1
		| Should -BeGreaterThan ([version]'5.0.0')
  }

  It 'Detects module in other psmodulePath' {
    $installPath2 = Join-Path $testdrive $(New-Guid)
    New-Item -ItemType Directory $installPath2 | Out-Null
    $env:PSModulePath = "$installPath2"
    Install-ModuleFast @imfParams -Destination $installPath2 'PreReleaseTest'
    Install-ModuleFast @imfParams 'PreReleaseTest' -PassThru | Should -BeNullOrEmpty
  }

  It 'Only considers destination modules if -DestinationOnly is specified' {
    $installPath2 = Join-Path $testdrive $(New-Guid)
    New-Item -ItemType Directory $installPath2 | Out-Null
    $env:PSModulePath = "$installPath2"
    Install-ModuleFast @imfParams -Destination $installPath2 'PreReleaseTest'
    Install-ModuleFast @imfParams 'PreReleaseTest' -DestinationOnly -PassThru | Should -HaveCount 1
    Install-ModuleFast @imfParams 'PreReleaseTest' -DestinationOnly -PassThru | Should -BeNullOrEmpty
  }

  It '-DestinationOnly works on modules with dependencies' {
    Install-ModuleFast @imfParams 'Az.Compute' -DestinationOnly -PassThru | Should -HaveCount 2
  }

  It 'Errors trying to install prerelease over regular module' {
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1'
    { Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-prerelease' }
    | Should -Throw '*is newer than the requested prerelease version*'
  }
  It 'Errors trying to install older prerelease over regular module' {
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1'
    { Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-prerelease' }
    | Should -Throw '*is newer than the requested prerelease version*'
  }
  It 'Installs regular module over prerelease module with warning' {
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-prerelease'
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1' -WarningVariable actual *>&1 | Out-Null
    $actual | Should -BeLike '*is newer than existing prerelease version*'
  }
  It 'Installs newer prerelease with warning' {
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-aprerelease'
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-bprerelease' -WarningVariable actual *>&1 | Out-Null
    $actual | Should -BeLike '*is newer than existing prerelease version*'
  }
  It 'Doesnt install prerelease if same-version Prerelease already installed' {
    Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-prerelease'
    $plan = Install-ModuleFast @imfParams 'PrereleaseTest=0.0.1-prerelease' -Plan
    $plan | Should -BeNullOrEmpty
  }

  It 'Installs from <Name> SpecFile' {
    $SCRIPT:Mocks = Resolve-Path "$PSScriptRoot/Test/Mocks"
    $specFilePath = Join-Path $Mocks $File
    $modulesToInstall = Install-ModuleFast @imfParams -Path $specFilePath -Plan
    #TODO: Verify individual modules and versions
    $modulesToInstall | Should -Not -BeNullOrEmpty
  } -TestCases @(
    @{
      Name = 'PowerShell Data File'
      File = 'ModuleFast.requires.psd1'
    },
    @{
      Name = 'JSON'
      File = 'ModuleFast.requires.json'
    },
    @{
      Name = 'JSONArray'
      File = 'ModuleFastArray.requires.json'
    },
    @{
      Name = 'ScriptRequires'
      File = 'RequiresScript.ps1'
    },
    @{
      Name = 'ScriptModule'
      File = 'RequiresModule.psm1'
    },
    @{
      Name = 'DynamicManifest'
      File = 'Dynamic.psd1'
    }
  )

  It 'Fails for script if #Requires is not Present' {
    $scriptPath = Join-Path $testDrive 'norequires.ps1'
    {
      'There is no requires here!'
    } | Out-File $scriptPath

    { Install-ModuleFast @imfParams -Path $scriptPath }
    | Should -Throw 'The script does not have a #Requires*'
  }
  It 'Fails for module if #Requires is not Present' {
    $scriptPath = Join-Path $testDrive 'norequires.psm1'
    {
      'There is no requires here!'
    } | Out-File $scriptPath

    { Install-ModuleFast @imfParams -Path $scriptPath }
    | Should -Throw 'The script does not have a #Requires*'
  }
  It 'Fails if Module Manifest and RequiredModules is missing' {
    $scriptPath = Join-Path $testDrive 'testmanifestnorequires.psd1'
    "@{
      'ModuleVersion'   = '1.0.0'
    }" | Out-File $scriptPath
    { Install-ModuleFast @imfParams -Path $scriptPath }
    | Should -Throw 'The manifest does not have a RequiredMOdules key*'
  }
  It 'Resolves Module Manifest RequiredModules' {
    $scriptPath = Join-Path $testDrive 'testmanifest.psd1'
    "@{
      'ModuleVersion'   = '1.0.0'
      'RequiredModules' = @(
        'PreReleaseTest'
        @{
          ModuleName = 'Az.Accounts'
          ModuleVersion = '2.7.0'
        }
      )
    }" | Out-File $scriptPath
    $modules = Install-ModuleFast @imfParams -Path $scriptPath -Plan
    $modules.count | Should -Be 2
  }
  It 'Resolves GUID with version range' {
    $scriptPath = Join-Path $testDrive 'testscript.ps1'
    "#requires -Module @{ModuleName='PreReleaseTest';Guid='7c279caf-00bc-40ae-a1ed-184ad07be1b0';ModuleVersion='0.0.1';MaximumVersion='0.0.2'}" | Out-File $scriptPath
    $actual = Install-ModuleFast @imfParams -WarningAction SilentlyContinue -Path $scriptPath -PassThru
    $actual.Name | Should -Be 'PrereleaseTest'
    $actual.ModuleVersion | Should -Be '0.0.1'
  }
  It 'Errors if GUID spec is different than installed module' {
    { Install-ModuleFast @imfParams -WarningAction SilentlyContinue -Specification "@{ModuleName='PreReleaseTest';Guid='3cb1a381-5d96-4b56-843e-dd97cf4c6545';ModuleVersion='0.0.1';MaximumVersion='0.0.2'}" -PassThru }
    | Should -Throw '*Expected 3cb1a381-5d96-4b56-843e-dd97cf4c6545 but found 7c279caf-00bc-40ae-a1ed-184ad07be1b0*'
  }

  It 'Writes a CI File' {
    Set-Location $testDrive
    Install-ModuleFast @imfParams -CI -Specification 'PreReleaseTest'
    Get-Item 'requires.lock.json' | Should -Not -BeNullOrEmpty
    #TODO: CI Content
  }

  It 'Installs from CI File and Installs CI Pinned Version' {
    Set-Location $testDrive
    Install-ModuleFast @imfParams -CI -Specification 'PreReleaseTest=0.0.1-prerelease'
    Get-Item 'requires.lock.json' | Should -Not -BeNullOrEmpty

    Remove-Item $imfParams.Destination -Recurse -Force
    New-Item -ItemType Directory -Path $imfParams.Destination -ErrorAction stop
    Install-ModuleFast @imfParams -CI
    $PreReleaseManifest = "$($imfParams.Destination)\PreReleaseTest\0.0.1\PreReleaseTest.psd1"
    Resolve-Path $PreReleaseManifest

    (Import-PowerShellDataFile $PreReleaseManifest).PrivateData.PSData.Prerelease
    | Should -Be 'prerelease' -Because 'CI lock file should have 0.1 prerelease even if 0.2 is available'
    #TODO: CI Content
  }

  It 'Handles an incomplete installation' {
    $incompleteItemPath = "$installTempPath\PreReleaseTest\0.0.1\.incomplete"
    Install-ModuleFast @imfParams -Specification 'PreReleaseTest=0.0.1'
    New-Item -ItemType File -Path $incompleteItemPath
    Install-ModuleFast @imfParams -Specification 'PreReleaseTest=0.0.1' -Update -WarningVariable actual 3>$null
    $actual | Should -BeLike '*incomplete installation detected*'
    Test-Path $incompleteItemPath | Should -BeFalse
  }

  It 'PassThru only reports on installed modules' {
    Install-ModuleFast @imfParams -Specification 'Pester=5.4.0', 'Pester=5.4.1' -PassThru | Should -HaveCount 2
    Install-ModuleFast @imfParams -Specification 'Pester=5.4.0', 'Pester=5.4.1' -PassThru | Should -HaveCount 0
  }

  Describe 'GitHub Packages' {
    It 'Gets Specific Module' {
      $credential = [PSCredential]::new('Pester', (Get-Secret -Name 'ReadOnlyPackagesGithubPAT'))
      $actual = Install-ModuleFast @imfParams -Specification 'PrereleaseTest=0.0.1' -Source 'https://nuget.pkg.github.com/justingrote/index.json' -Credential $credential -Plan
      $actual.Name | Should -Be 'PrereleaseTest'
      $actual.ModuleVersion -as 'NuGet.Versioning.NuGetVersion' | Should -Be '0.0.1'
    }
  }

  Describe 'Plan Parameter' {
    It 'Does not install if Plan is specified' {
      Install-ModuleFast @imfParams -Specification 'PrereleaseTest' -Plan | Should -Match 'PreReleaseTest'
      Test-Path $installTempPath\PreReleaseTest | Should -BeFalse
    }
  }
}

