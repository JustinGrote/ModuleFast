BeforeAll {
  . ./ModuleFast.ps1
}
Describe 'Get-ModuleFastPlan' {
  It 'Gets Module' {
    Get-ModuleFastPlan 'ImportExcel'
  }
  It 'Gets Module with 1 dependency' {
    Get-ModuleFastPlan 'Az.Compute'
  }
  It 'Gets Module with lots of dependencies (Az)' {
    #TODO: Mocks
    Get-ModuleFastPlan 'Az' | Should -HaveCount 77
  }
  It 'Gets Az Module limiting batch connections to 4' {
    #TODO: Mocks
    Get-ModuleFastPlan 'Az' -MaxBatchConnections 4 | Should -HaveCount 77
  }
}