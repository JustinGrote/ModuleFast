BeforeAll {
  . ./ModuleFast.ps1
}
Describe 'Get-PSGalleryModule' {
  It 'Gets Module' {
    Get-ModuleFast 'ImportExcel'
  }
}