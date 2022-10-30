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
    Get-ModuleFastPlan 'Az'
  }
}