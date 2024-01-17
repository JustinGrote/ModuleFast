@{
  PSDependOptions = @{
    Repository     = 'PSGallery'
    DependencyType = 'FileDownload'
  }

  nuget           = @{
    Source = 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe'
    Target = 'C:\nuget.exe'
  }
}
