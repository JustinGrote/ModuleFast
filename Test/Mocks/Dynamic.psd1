@{
  ModuleVersion   = '1.0.0'
  RootModule      = if ($true) {
    'coreclr\PrtgAPI.PowerShell.dll'
  } else {
    # Desktop
    'fullclr\PrtgAPI.PowerShell.dll'
  }
  RequiredModules = @('PrereleaseTest')
}
