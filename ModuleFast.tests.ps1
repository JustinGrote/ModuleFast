using namespace System.Management.Automation
using namespace System.Collections.Generic

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
      $spec = [ModuleSpecification][ModuleFastSpec]::new('Test', '1.2.3', $null)
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
    }
    It 'parses a build version' {
      $version = '1.2.3.4'
      $result = [ModuleFastSpec]::ParseVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Patch | Should -Be 3
      $result.BuildLabel | Should -Be 4
    }
  }
  Context 'ParseSemanticVersion' {
    It 'parses a normal version' {
      $version = '1.2.3'
      $result = [ModuleFastSpec]::ParseSemanticVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Build | Should -Be 3
    }
    It 'parses a build version' {
      $version = "1.2.3-$([ModuleFastSpec]::VersionBuildIdentifier)+4"
      $result = [ModuleFastSpec]::ParseSemanticVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Build | Should -Be 3
      $result.Revision | Should -Be 4
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

  Describe 'Compare' {
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


Describe 'Get-ModuleFastPlan' -Tag 'E2E' {
  $DebugPreference = 'contine'
  $VerbosePreference = 'continue'
  $SCRIPT:moduleName = 'Az.Accounts'
  It 'Gets Module by <Test>' {
    $actual = Get-ModuleFastPlan $spec
    $actual | Should -HaveCount 1
    $actual.Name | Should -Be $moduleName
    $actual.RequiredVersion -as [Version] | Should -Not -BeNullOrEmpty
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
}