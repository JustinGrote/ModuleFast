BeforeAll {
  . ./ModuleFast.ps1
  if ($env:MFURI) {
    $debugPreference = 'continue'
    $verbosePreference = 'continue'
    $PSDefaultParameterValues['Get-ModuleFastPlan:Source'] = $env:MFURI
  }
}
Describe 'Get-ModuleFastPlan' -Tag 'E2E' {
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