using namespace System.Management.Automation
using namespace System.Collections.Generic
using namespace System.Diagnostics.CodeAnalysis

BeforeAll {
  . ./ModuleFast.ps1
  if ($env:MFURI) {
    $PSDefaultParameterValues['Get-ModuleFastPlan:Source'] = $env:MFURI
  }
}

Describe 'ModuleFastSpec' {
  Context 'Constructors' {
    It 'Name' {
      $spec = [ModuleFastSpec]'Test'
      $spec.Name | Should -Be 'Test'
      $spec.Guid | Should -Be ([Guid]::Empty)
      $spec.Min | Should -Be ([ModuleFastSpec]::MinVersion)
      $spec.Max | Should -Be ([ModuleFastSpec]::MaxVersion)
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
      $spec.Max | Should -Be ([ModuleFastSpec]::MaxVersion)
      $spec.Required | Should -BeNull
    }
  }

  Context 'ModuleSpecification Conversion' {
    It 'Name' {
      $spec = [ModuleSpecification][ModuleFastSpec]'Test'
      $spec.Name | Should -Be 'Test'
      $spec.Version | Should -Be '0.0.0'
    }
    It 'RequiredVersion' {
      $spec = [ModuleSpecification][ModuleFastSpec]::new('Test', '1.2.3')
      $spec.Name | Should -Be 'Test'
      $spec.RequiredVersion | Should -Be '1.2.3'
    }
    It 'ModuleVersion' {
      $spec = [ModuleSpecification][ModuleFastSpec]::new('Test', '1.2.3', '')
      $spec.Name | Should -Be 'Test'
      $spec.Version | Should -Be '1.2.3'
    }
  }

  # Deprecated in favor of ModuleSpecification since we can have only 1 implicit cast
  # Context 'Version Implicit Conversion' {
  #   It 'Converts to Version' {
  #     $spec = [ModuleFastSpec]::new('Test', '1.2.3')
  #     [Version]$spec | Should -Be ([Version]'1.2.3')

  #   }
  #   It 'Converts to Version with Build Number' {
  #     $spec = [ModuleFastSpec]::new('Test', '1.2.3.1')
  #     [Version]$spec | Should -Be ([Version]'1.2.3.1')
  #   }
  #   It 'Converts to Version with Build Number' {
  #     $spec = [ModuleFastSpec]::new('Test', '1.2.3.1')
  #     [Version]$spec | Should -Be ([Version]'1.2.3.1')
  #   }
  # }

  Context 'ParseVersion' {
    It 'parses a normal version' {
      $version = '1.2.3'
      $result = [ModuleFastSpec]::ParseVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Patch | Should -Be 3
      $result.PreReleaseLabel | Should -BeNull
      $result.BuildLabel | Should -BeNull
      [ModuleFastSpec]::ParseSemanticVersion($result) | Should -BeExactly $version
    }
    It 'parses a system version' {
      $version = '1.2.3.4'
      $result = [ModuleFastSpec]::ParseVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Patch | Should -Be (3 + 1)
      $result.PreReleaseLabel | Should -Be (4).ToString().PadLeft(10, '0')
      $result.BuildLabel | Should -Be 'SYSTEMVERSION.HASREVISION'
      [ModuleFastSpec]::ParseSemanticVersion($result) | Should -BeExactly $version
    }
    It 'parses a major/minor only version' {
      $version = '1.4'
      $result = [ModuleFastSpec]::ParseVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 4
      $result.Patch | Should -Be 0
      $result.PreReleaseLabel | Should -BeNull
      $result.BuildLabel | Should -Be 'SYSTEMVERSION.NOBUILD'
      [ModuleFastSpec]::ParseSemanticVersion($result) | Should -BeExactly $version
    }
    It 'parses a patch version being zero' {
      $version = '1.4.0.5'
      $result = [ModuleFastSpec]::ParseVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 4
      $result.Patch | Should -Be (0 + 1)
      $result.PreReleaseLabel | Should -Be (5).ToString().PadLeft(10, '0')
      $result.BuildLabel | Should -Be 'SYSTEMVERSION.HASREVISION'
      [ModuleFastSpec]::ParseSemanticVersion($result) | Should -BeExactly $version
    }
  }
  Context 'ParseSemanticVersion' {
    It 'parses a normal version' {
      $version = '1.2.3'
      $result = [ModuleFastSpec]::ParseSemanticVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Build | Should -Be 3
      $result.Revision | Should -Be -1
    }
    It 'strips non-version fields' {
      $version = '1.2.3-something+4'
      $result = [ModuleFastSpec]::ParseSemanticVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Build | Should -Be 3
      $result.Revision | Should -Be -1
    }
  }
  Context 'Overlap' {
    It 'overlaps exactly' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $spec1.Overlaps($spec2) | Should -BeTrue
      $spec2.Overlaps($spec1) | Should -BeTrue
    }
    It 'overlaps partially' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.1', '1.2.4')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.5')
      $spec1.Overlaps($spec2) | Should -BeTrue
      $spec2.Overlaps($spec1) | Should -BeTrue
    }
    It 'no overlap' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.1', '1.2.2')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $spec1.Overlaps($spec2) | Should -BeFalse
      $spec2.Overlaps($spec1) | Should -BeFalse
    }
    It 'overlaps partially with no max' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.1', '1.2.4')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3')
      $spec1.Overlaps($spec2) | Should -BeTrue
      $spec2.Overlaps($spec1) | Should -BeTrue
    }
    It 'overlaps partially with no min' {
      $spec1 = [ModuleFastSpec]::new('Test', $null, '1.2.4')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3')
      $spec1.Overlaps($spec2) | Should -BeTrue
      $spec2.Overlaps($spec1) | Should -BeTrue
    }
    It 'overlaps partially with no min or max' {
      $spec1 = [ModuleFastSpec]'Test'
      $spec2 = [ModuleFastSpec]'Test'
      $spec1.Overlaps($spec2) | Should -BeTrue
      $spec2.Overlaps($spec1) | Should -BeTrue
    }
    It 'errors on different Names' {
      $spec1 = [ModuleFastSpec]'Test'
      $spec2 = [ModuleFastSpec]'Test2'
      { $spec1.Overlaps($spec2) } | Should -Throw
      { $spec2.Overlaps($spec1) } | Should -Throw
    }
    It 'errors on different GUIDs' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.0.0', [Guid]::NewGuid())
      $spec2 = [ModuleFastSpec]::new('Test', '1.0.0', [Guid]::NewGuid())
      { $spec1.Overlaps($spec2) } | Should -Throw
      { $spec2.Overlaps($spec1) } | Should -Throw
    }
  }
  Context 'Equals' {
    It 'ModuleFastSpec' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $spec1 -eq $spec2 | Should -BeTrue
    }
    It 'ModuleFastSpec not equal on name' {
      $spec1 = [ModuleFastSpec]'Test'
      $spec2 = [ModuleFastSpec]'Test2'
      $spec1 -eq $spec2 | Should -BeFalse
    }
    It 'ModuleFastSpec not equal on min' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.4')
      $spec1 -eq $spec2 | Should -BeFalse
    }
    It 'ModuleFastSpec not equal on max' {
      $spec1 = [ModuleFastSpec]::new('Test', $null, '1.2.3')
      $spec2 = [ModuleFastSpec]::new('Test', $null, '1.2.4')
      $spec1 -eq $spec2 | Should -BeFalse
    }
    It 'Version In Range' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $version = [Version]::new('1.2.3')
      $spec1 -eq $version | Should -BeTrue
    }
    It 'Version NotIn Range' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $version = [Version]::new('1.2.2')
      $spec1 -eq $version | Should -BeFalse
    }
    It 'SemanticVersion In Range' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $version = [SemanticVersion]::new('1.2.3')
      $spec1 -eq $version | Should -BeTrue
    }
    It 'SemanticVersion NotIn Range' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
      $version = [SemanticVersion]::new('1.2.3')
      $spec1 -eq $version | Should -BeTrue
    }

    #TODO: Impelement guid constructor
    # It 'ModuleFastSpec not equal on guid' {
    #   $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4', [Guid]::NewGuid())
    #   $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4', [Guid]::NewGuid())
    #   $spec1 -eq $spec2 | Should -BeFalse
    # }

    It 'String Comparisons' {
      $spec = [ModuleFastSpec]::new('Test', '1.1.1', '2.2.2')
      $spec -eq '1' | Should -BeFalse
      $spec -eq '2' | Should -BeTrue
      $spec -eq '3' | Should -BeFalse
      $spec -eq '1.0' | Should -BeFalse
      $spec -eq '1.1' | Should -BeFalse
      $spec -eq '1.2' | Should -BeTrue
      $spec -eq '2.0' | Should -BeTrue
      $spec -eq '2.2' | Should -BeTrue
      $spec -eq '2.3' | Should -BeFalse
      $spec -eq '3.0' | Should -BeFalse
      $spec -eq '1.1.0' | Should -BeFalse
      $spec -eq '1.1.1' | Should -BeTrue
      $spec -eq '1.1.2' | Should -BeTrue
      $spec -eq '2.2.2' | Should -BeTrue
      $spec -eq '2.2.3' | Should -BeFalse
      $spec -eq '3.0.0' | Should -BeFalse
    }
  }

  Context 'Compare' {
    It 'Sorts' {
      $spec1 = [ModuleFastSpec]::new('Test', '1.2.3')
      $spec2 = [ModuleFastSpec]::new('Test', '1.2.4')
      $spec3 = [ModuleFastSpec]::new('Test', '1.2.5')
      $spec3, $spec1, $spec2
      | Sort-Object
      | Should -Be @( $spec1, $spec2, $spec3 )

      $spec3, $spec1, $spec2
      | Sort-Object -Descending
      | Should -Be @( $spec3, $spec2, $spec1 )
    }
  }
}

Describe 'HashSet Dedupe (GetHashCode)' {
  It 'Name' {
    $spec1 = [ModuleFastSpec]'Test'
    $spec2 = [ModuleFastSpec]'Test'
    $spec1.GetHashCode() | Should -Be $spec2.GetHashCode()
  }
  It 'RequiredVersion' {
    $spec1 = [ModuleFastSpec]::new('Test', '1.2.3')
    $spec2 = [ModuleFastSpec]::new('Test', '1.2.3')
    $spec1.GetHashCode() | Should -Be $spec2.GetHashCode()
  }
  It 'Min and Max Version' {
    $spec1 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
    $spec2 = [ModuleFastSpec]::new('Test', '1.2.3', '1.2.4')
    $spec1.GetHashCode() | Should -Be $spec2.GetHashCode()
  }
  It 'Max Version Only' {
    $spec1 = [ModuleFastSpec]::new('Test', $null, '1.2.4')
    $spec2 = [ModuleFastSpec]::new('Test', $null, '1.2.4')
    $spec1.GetHashCode() | Should -Be $spec2.GetHashCode()
  }
  It 'Min Version Only' {
    $spec1 = [ModuleFastSpec]::new('Test', '1.2.3')
    $spec2 = [ModuleFastSpec]::new('Test', '1.2.3')
    $spec1.GetHashCode() | Should -Be $spec2.GetHashCode()
  }
  It 'Guid' {
    [HashSet[ModuleFastSpec]]$hs = @{}
    $guid = [Guid]::NewGuid()
    $spec1 = [ModuleFastSpec]::new('Test', '1.2.4', $guid)
    $hs.Add($spec1) | Should -BeTrue
    $spec2 = [ModuleFastSpec]::new('Test', '1.2.4', $guid)
    $hs.Add($spec2) | Should -BeFalse
  }
}

Describe 'NugetRange' {
  Context 'Decrement' {
    It '<In> should be <Out>' {
      $actual = [NugetRange]::Decrement($In)
      $actual | Should -Be $Out
      $actual | Should -BeLessThan $In
    } -TestCases @(
      @{In = '1.0.1-build+5'; Out = '1.0.0' }
      @{In = '1.0.1'; Out = '1.0.0' }
      @{In = '1.0.2'; Out = '1.0.1' }
      @{In = '1.1.2'; Out = '1.1.1' }
      @{In = '0.1.2'; Out = '0.1.1' }
    )
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
    $actual.Name | Should -Be $moduleName
    $actual.Required -as [Version] | Should -Not -BeNullOrEmpty
  } -TestCases (
    @{Test = 'Name'; Spec = $moduleName },
    @{Test = 'MinimumVersion'; Spec = @{ ModuleName = $moduleName; ModuleVersion = '0.0.0' } },
    @{Test = 'RequiredVersionNotLatest'; Spec = @{ ModuleName = $moduleName; RequiredVersion = '2.7.3' } }
  )
  It 'Gets Module with 1 dependency' {
    Get-ModuleFastPlan 'Az.Compute' | Should -HaveCount 2
  }
  It 'Gets Module with lots of dependencies (Az)' {
    #TODO: Mocks
    Get-ModuleFastPlan 'Az' | Should -HaveCount 78
  }
  It 'Gets Module with 4 section version number and a 4 section version number dependency (VMware.VimAutomation.Common)' {
    Get-ModuleFastPlan 'VMware.VimAutomation.Common' | Should -HaveCount 2

  }
  It 'Gets multiple modules' {
    Get-ModuleFastPlan 'Az', 'VMware.PowerCLI' | Should -HaveCount 153
  }
}

Describe 'Install-ModuleFast' -Tag 'E2E' {
  BeforeAll {
    $SCRIPT:__existingPSModulePath = $env:PSModulePath
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
    Get-Module VMWare* -ListAvailable | Should -HaveCount 2
  }
  It 'lots of dependencies (Az)' {
    Install-ModuleFast @imfParams 'Az'
    (Get-Module Az* -ListAvailable).count | Should -BeGreaterThan 10
  }
  It 'specific requiredVersion' {
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.7.4' }
    Get-Module Az.Accounts -ListAvailable | Select-Object -ExpandProperty Version | Should -Be '2.7.4'
  }
  It 'specific requiredVersion when newer version is present' {
    Install-ModuleFast @imfParams 'Az.Accounts'
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; RequiredVersion = '2.7.4' }
    $installedVersions = Get-Module Az.Accounts -ListAvailable | Select-Object -ExpandProperty Version
    $installedVersions | Should -HaveCount 2
    $installedVersions | Should -Contain '2.7.4'
  }
  It 'Installs when Maximumversion is lower than currently installed' {
    $DebugPreference = 'continue'
    Install-ModuleFast @imfParams 'Az.Accounts'
    Install-ModuleFast @imfParams @{ ModuleName = 'Az.Accounts'; MaximumVersion = '2.7.3' }
    Get-Module Az.Accounts -ListAvailable | Select-Object -ExpandProperty Version | Should -Contain '2.7.3'
  }
}