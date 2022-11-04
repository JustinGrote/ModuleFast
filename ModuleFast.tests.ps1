using namespace System.Management.Automation

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

    It 'Has immutable properties' {
      $spec = [ModuleFastSpec]'Test'
      { $spec.Min = '1' } | Should -Throw
      { $spec.Max = '1' } | Should -Throw
      { $spec.Required = '1' } | Should -Throw
      { $spec.Name = 'fake' } | Should -Throw
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

  Context 'ModuleSpecification Implicit Conversion' {
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
      $version = '1.2.3-MFbuildMF+4'
      $result = [ModuleFastSpec]::ParseSemanticVersion($version)
      $result.Major | Should -Be 1
      $result.Minor | Should -Be 2
      $result.Build | Should -Be 3
      $result.Revision | Should -Be 4
    }
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