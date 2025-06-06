#requires -version 7.2
using namespace Microsoft.PowerShell.Commands
using namespace NuGet.Versioning
using namespace System.Collections
using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.IO
using namespace System.IO.Compression
using namespace System.IO.Pipelines
using namespace System.Management.Automation
using namespace System.Management.Automation.Language
using namespace System.Net
using namespace System.Net.Http
using namespace System.Reflection
using namespace System.Runtime.Caching
using namespace System.Text
using namespace System.Threading
using namespace System.Threading.Tasks

#Because we are changing state, we want to be safe
#TODO: Implement logic to only fail on module installs, such that one module failure doesn't prevent others from installing.
#Probably need to take into account inconsistent state, such as if a dependent module fails then the depending modules should be removed.
$ErrorActionPreference = 'Stop'

if ($ENV:CI) {
  Write-Verbose 'CI Environment Variable is set, this indicates a Continuous Integration System is being used. ModuleFast will suppress prompts by setting ConfirmPreference to None and forcing confirmations to false. This is to ensure that ModuleFast can be used in CI/CD systems without user interaction.'
  #Module Scope which should carry to other called commands
  $SCRIPT:ConfirmPreference = 'None'
  $PSDefaultParameterValues['Install-ModuleFast:Confirm'] = $false
}

#Default Source is PWSH Gallery
$SCRIPT:DefaultSource = 'https://pwsh.gallery/index.json'

#region Public

enum InstallScope {
  CurrentUser
  AllUsers
}



function Install-ModuleFast {
  <#
  .SYNOPSIS
  High performance, declarative Powershell Module Installer
  .DESCRIPTION
  ModuleFast is a high performance, declarative PowerShell module installer. It is optimized for speed and written primarily in PowerShell and can be bootstrapped in a single line of code. It is ideal for Continuous Integration/Deployment and serverless scenarios where you want to install modules quickly and without any user interaction. It is inspired by PNPm (https://pnpm.io/) and other high performance declarative package managers.

  ModuleFast accepts a variety of familiar PowerShell syntaxes and objects for module specification as well as a custom shorthand syntax allowing complex version requirements to be defined in a single string.

  ModuleFast can also install the required modules specified in the #Requires line of a script, or in the RequiredModules section of a module manifest, by simplying providing the path to that file in the -Path parameter (which also accepts remote UNC, http, and https URLs).

  ---------------------------
  Module Specification Syntax
  ---------------------------
  ModuleFast supports a shorthand string syntax for defining module specifications. It generally takes the form of '<Module><Operator><Version>'. The version supports SemVer 2 and prerelease tags.

  The available operators are:
  - '=': Exact version match. Examples: 'ImportExcel=7.1.0', 'ImportExcel=7.1.0-preview'
  - '>': Greater than. Example: 'ImportExcel>7.1.0'
  - '>=': Greater than or equal to. Example: 'ImportExcel>=7.1.0'
  - '<': Less than. Example: 'ImportExcel<7.1.0'
  - '<=': Less than or equal to. Example: 'ImportExcel<=7.1.0'
  - '!': A prerelease operator that can be present at the beginning or end of a module name to indicate that prerelease versions are acceptable. Example: 'ImportExcel!', '!ImportExcel'. It can be combined with the other operators like so: 'ImportExcel!>7.1.0'
  - ':': Lets you specify a NuGet version range. Example: 'ImportExcel:(7.0.0, 7.2.1-preview]'

  For more information about NuGet version range syntax used with the ':' operator: https://learn.microsoft.com/en-us/nuget/concepts/package-versioning#version-ranges. Wilcards are supported with this syntax e.g. 'ImportExcel:3.2.*' will install the latest 3.2.x version.

  ModuleFast also fully supports the ModuleSpecification object and hashtable-like string syntaxes that are used by Install-Module and Install-PSResource. More information on this format: https://learn.microsoft.com/en-us/dotnet/api/microsoft.powershell.commands.modulespecification?view=powershellsdk-7.4.0

  -------
  Logging
  -------
  Modulefast has extensive Verbose and Debug information available if you specify the -Verbose and/or -Debug parameters. This can be useful for troubleshooting or understanding how ModuleFast is working. Verbose level provides a high level "what" view of the process of module selection, while Debug level provides a much more detailed "Why" information about the module selection and installation process that can be useful in troubleshooting issues.

  -----------------
  Installation Path
  -----------------
  ModuleFast will install modules to the default PowerShell module path on non-Windows platforms. On Windows, it will install to %LOCALAPPDATA%\PowerShell\Modules by default as the default Documents PowerShell Modules folder has increasing caused problems due to conflicts with document syncing programs such as OneDrive. You can override this behavior by specifying the -Destination parameter. You can also specify 'CurrentUser' to install to the legacy Documents PowerShell Modules folder on Windows only.

  As part of this installation process on Windows, ModuleFast will add the destination to your PSModulePath for the current session. This is done to ensure that the modules are available for use in the current session. If you do not want this behavior, you can specify the -NoPSModulePathUpdate switch.

  In addition, if you do not already have the %LOCALAPPDATA%\PowerShell\Modules in your $env:PSModulesPath, Modulefast will append a command to add it to your user profile. This is done to ensure that the modules are available for use in future sessions. If you do not want this behavior, you can specify the -NoProfileUpdate switch.

  -------
  Caching
  -------
  ModuleFast will cache the results of the module selection process in memory for the duration of the PowerShell session. This is done to improve performance when multiple modules are being installed. If you want to clear the cache, you can call Clear-ModuleFastCache.

  .PARAMETER WhatIf
  Outputs the installation plan of modules not already available and needing to be installed to the pipeline as well as the console. This can be saved and provided to Install-ModuleFast at a later date.

  .EXAMPLE
  Install-ModuleFast 'ImportExcel' -PassThru

  Installs the latest version of ImportExcel and outputs info about the installed modules. Remove -PassThru for a quieter installation, or add -Verbose or -Debug for even more information.

  --- RESULT ---
  Name                      ModuleVersion
  ----                      -------------
  ImportExcel               7.8.6

  .EXAMPLE
  Install-ModuleFast 'ImportExcel','VMware.PowerCLI.Sdk=12.6.0.19600125','PowerConfig<0.1.6','Az.Compute:7.1.*' -WhatIf

  Prepares an install plan for the latest version of ImportExcel, a specific version of VMware.PowerCLI.Sdk, a version of PowerConfig less than 0.1.6, and the latest version of Az.Compute that is in the 7.1.x range.

  --- RESULT ---
  Name                      ModuleVersion
  ----                      -------------
  VMware.PowerCLI.Sdk       12.6.0.19600125
  ImportExcel               7.8.6
  PowerConfig               0.1.5
  Az.Compute                7.1.0
  VMware.PowerCLI.Sdk.Types 12.6.0.19600125
  Az.Accounts               2.13.2

  .EXAMPLE
  'ImportExcel','VMware.PowerCLI.Sdk=12.6.0.19600125','PowerConfig<0.1.6','Az.Compute:7.1.*' | Install-ModuleFast -WhatIf

  Same as the previous example, but using the pipeline to provide the module specifications.

  --- RESULT ---
  Name                      ModuleVersion
  ----                      -------------
  VMware.PowerCLI.Sdk       12.6.0.19600125
  ImportExcel               7.8.6
  PowerConfig               0.1.5
  Az.Compute                7.1.0
  VMware.PowerCLI.Sdk.Types 12.6.0.19600125
  Az.Accounts               2.13.2


  .EXAMPLE
  $plan = Install-ModuleFast 'ImportExcel' -WhatIf
  $plan | Install-ModuleFast

  Stores an Install Plan for ImportExcel in the $plan variable, then installs it. The later install can be done later, and the $plan objects are serializable to CLIXML/JSON/etc. for storage.

  --- RESULT ---

  What if: Performing the operation "Install 1 Modules" on target "C:\Users\JGrote\AppData\Local\powershell\Modules".  Name        ModuleVersion

  Name        ModuleVersion
  ----        -------------
  ImportExcel 7.8.6

  .EXAMPLE
  @{ModuleName='ImportExcel';ModuleVersion='7.8.6'} | Install-ModuleFast

  Installs a specific version of ImportExcel using

  .EXAMPLE
  Install-ModuleFast 'ImportExcel' -Destination 'CurrentUser'

  Installs ImportExcel to the legacy PowerShell Modules folder in My Documents on Windows only, but does not update the PSModulePath or the user profile to include the new module path. This behavior is similar to Install-Module or Install-PSResource.

  .EXAMPLE
  Install-ModuleFast -Path 'path\to\RequiresScript.ps1' -WhatIf

  Prepares a plan to install the dependencies defined in the #Requires statement of a script if a .ps1 is specified, the #Requires statement of a module if .psm1 is specified, or the RequiredModules section of a .psd1 file if it is a PowerShell Module Manifest. This is useful for quickly installing dependencies for scripts or modules.

  RequiresScript.ps1 Contents:
  #Requires -Module PreReleaseTest

  --- RESULT ---

  What if: Performing the operation "Install 1 Modules" on target "C:\Users\JGrote\AppData\Local\powershell\Modules".

  Name           ModuleVersion
  ----           -------------
  PrereleaseTest 0.0.1

  .EXAMPLE
  Install-ModuleFast -WhatIf

  If no Specification or Path parameter is provided, ModuleFast will search for a .requires.json or a .requires.psd1 file in the current directory and install the modules specified in that file. This is useful for quickly installing dependencies for scripts or modules during a CI build or Github Action.

  Note that for this format you can explicitly specify 'latest' or ':*' as the version to install the latest version of a module.

  Module.requires.psd1 Contents:
  @{
    ImportExcel = 'latest'
    'VMware.PowerCLI.Sdk' = '>=12.6.0.19600125'
  }

  --- RESULT ---

  Name                      ModuleVersion
  ----                      -------------
  ImportExcel               7.8.6
  VMware.PowerCLI.Sdk       12.6.0.19600125
  VMware.PowerCLI.Sdk.Types 12.6.0.19600125

  .EXAMPLE
  Install-ModuleFast 'ImportExcel' -CI #This will write a lockfile to the current directory
  Install-ModuleFast -CI #This will use the previously created lockfile to install same state as above.

  If the -CI switch is specified, ModuleFast will write a lockfile to the current directory indicating all modules that were installed. This lockfile will contain the exact versions of the modules that were installed. If the lockfile is present in the future, ModuleFast will only install the versions specified in the lockfile, which is useful for reproducing CI builds even if newer versions of modules are releases that match the initial specification.

  For instance, the above will install the latest version of ImportExcel (7.8.6 as of this writing) but will not install newer while modulefast is in this directory until the lockfile is removed or replaced.

  #>

  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Specification')]
  param(
    #The module(s) to install. This can be a string, a ModuleSpecification, a hashtable with nuget version style (e.g. @{Name='test';Version='1.0'}), a hashtable with ModuleSpecification style (e.g. @{Name='test';RequiredVersion='1.0'}),
    [Alias('Name')]
    [Alias('ModuleToInstall')]
    [Alias('ModulesToInstall')]
    [AllowNull()]
    [AllowEmptyCollection()]
    [Parameter(Position = 0, ValueFromPipeline, ParameterSetName = 'Specification')][ModuleFastSpec[]]$Specification,

    #Provide a required module specification path to install from. This can be a local psd1/json file, or a remote URL with a psd1/json file in supported manifest formats, or a .ps1/.psm1 file with a #Requires statement.
    [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
    #Explicitly specify the type of SpecFile to use. ModuleFast has some limited autodetection capability for ModuleBuilder and PSDepend formats, you should use this parameter if they explicitly fail. This is ignored if the file is not a .psd1 file.
    [Parameter(ParameterSetName = 'Path')][SpecFileType]$SpecFileType = [SpecFileType]::AutoDetect,
    #Where to install the modules. This defaults to the builtin module path on non-windows and a custom LOCALAPPDATA location on Windows. You can also specify 'CurrentUser' to install to the Documents folder on Windows Only (this is not recommended)
    [string]$Destination,
    #The repository to scan for modules. TODO: Multi-repo support
    [string]$Source = $SCRIPT:DefaultSource,
    #The credential to use to authenticate. Only basic auth is supported
    [PSCredential]$Credential,
    #By default will modify your PSModulePath to use the builtin destination if not present. Setting this implicitly skips profile update as well.
    [Switch]$NoPSModulePathUpdate,
    #Setting this won't add the default destination to your powershell.config.json. This really only matters on Windows.
    [Switch]$NoProfileUpdate,
    #Setting this will check for newer modules if your installed modules are not already at the upper bound of the required version range. Note that specifying this will also clear the local request cache for remote repositories which will result in slower evaluations if the information has not changed.
    [Switch]$Update,
    #Prerelease packages will be included in ModuleFast evaluation. If a non-prerelease package has a prerelease dependency, that dependency will be included regardless of this setting. If this setting is specified, all packages will be evaluated for prereleases regardless of if they have a prerelease indicator such as '!' in their specification name, but will still be subject to specification version constraints that would prevent a prerelease from installing.
    [Switch]$Prerelease,
    #Using the CI switch will write a lockfile to the current folder. If this file is present and -CI is specified in the future, ModuleFast will only install the versions specified in the lockfile, which is useful for reproducing CI builds even if newer versions of software come out.
    [Switch]$CI,
    #Only consider the specified destination and not any other paths currently in the PSModulePath. This is useful for CI scenarios where you want to ensure that the modules are installed in a specific location.
    [Switch]$DestinationOnly,
    #How many concurrent installation threads to run. Each installation thread, given sufficient bandwidth, will likely saturate a full CPU core with decompression work. This defaults to the number of logical cores on the system. If your system uses HyperThreading and presents more logical cores than physical cores available, you may want to set this to half your number of logical cores for best performance.
    [int]$ThrottleLimit = [Environment]::ProcessorCount,
    #The path to the lockfile. By default it is requires.lock.json in the current folder. This is ignored if -CI parameter is not present. It is generally not recommended to change this setting.
    [string]$CILockFilePath = $(Join-Path $PWD 'requires.lock.json'),
    #A list of ModuleFastInfo objects to install. This parameterset is used when passing a plan to ModuleFast via the pipeline and is generally not used directly.
    [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ModuleFastInfo')][ModuleFastInfo[]]$ModuleFastInfo,
    #Outputs the installation plan of modules not already available and needing to be installed to the pipeline as well as the console. This can be saved and provided to Install-ModuleFast at a later date. This is functionally the same as -WhatIf but without the additional WhatIf Output
    [Switch]$Plan,
    #This will output the resulting modules that were installed.
    [Switch]$PassThru,
    #Setting this to "CurrentUser" is the same as specifying the destination as 'Current'. This is a usability convenience.
    [InstallScope]$Scope,
    #The timeout for HTTP requests. This is set to 30 seconds by default. This is generally sufficient for most requests, but you may need to increase this if you are on a slow connection or are downloading large modules.
    [int]$Timeout = 30,
    #ModuleFast performs some friendly operations that aren't strictly SemVer compliant. For example, if you ask for Module!<3.0.0, technically 3.0.0-alpha should be returned via the SemVer spec, but typically that's not what people actually want, they want what would effectively be Module!<2.999.999, so we exclude these prereleases for good UX. Specify this switch to enforce strict SemVer behavior and return the prerelease in this scenario.
    [switch]$StrictSemVer
  )
  begin {
    trap {$PSCmdlet.ThrowTerminatingError($PSItem)}
    #Clear the ModuleFastCache if -Update is specified to ensure fresh lookups of remote module availability
    if ($Update) {
      Clear-ModuleFastCache
    }

    #Cleanup that allows for shorthand such as pwsh.gallery
    [Uri]$srcTest = $Source
    if ($srcTest.Scheme -notin 'http', 'https') {
      Write-Debug "Appending https and index.json to $Source"
      $Source = "https://$Source/index.json"
    }

    $defaultRepoPath = $(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'powershell/Modules')
    if (-not $Destination) {
      #Special function that will retrieve the default module path for the current user
      $Destination = Get-PSDefaultModulePath -AllUsers:($Scope -eq 'AllUsers')

      #Special case for Windows to avoid the default installation path because it has issues with OneDrive
	    $defaultWindowsModulePath = $isWindows ? (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules') : 'XXX___NOTSUPPORTED'

      if ($IsWindows -and $Destination -eq $defaultWindowsModulePath -and $Scope -ne 'CurrentUser') {
        Write-Debug "Windows Documents module folder detected. Changing to $defaultRepoPath"
        $Destination = $defaultRepoPath
      }
    }

    if (-not $Destination) {
      throw 'Failed to determine destination path. This is a bug, please report it, it should always have something by this point.'
    }



    # Require approval to create the destination folder if it is not our default path, otherwise this is automatic
    if (-not (Test-Path $Destination)) {
      if ($configRepoPath -or
          $Destination -eq $defaultRepoPath -or
          (Approve-Action 'Create Destination Folder' $Destination)
      ) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
      }
    }

    $Destination = Resolve-Path $Destination

    if (-not $NoPSModulePathUpdate) {
      # Get the current PSModulePath
      $PSModulePaths = $env:PSModulePath.Split([Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)

      #Only update if the module path is not already in the PSModulePath
      if ($Destination -notin $PSModulePaths) {
        Add-DestinationToPSModulePath -Destination $Destination -NoProfileUpdate:$NoProfileUpdate -Confirm:$Confirm
      }
    }

    #We want to maintain a single HttpClient for the life of the module. This isn't as big of a deal as it used to be but
    #it is still a best practice.
    if (-not $SCRIPT:__ModuleFastHttpClient -or $Source -ne $SCRIPT:__ModuleFastHttpClient.BaseAddress) {
      $SCRIPT:__ModuleFastHttpClient = New-ModuleFastClient -Credential $Credential -Timeout $Timeout
      if (-not $SCRIPT:__ModuleFastHttpClient) {
        throw 'Failed to create ModuleFast HTTPClient. This is a bug'
      }
    }
    $httpClient = $SCRIPT:__ModuleFastHttpClient

    $cancelSource = [CancellationTokenSource]::new()
    $cancelSource.CancelAfter([TimeSpan]::FromSeconds($Timeout))

    [HashSet[ModuleFastSpec]]$ModulesToInstall = @()
    [List[ModuleFastInfo]]$installPlan = @()
  }

  process {
    #We initialize and type the container list here because there is a bug where the ParameterSet is not correct in the begin block if the pipeline is used. Null conditional keeps it from being reinitialized

    switch ($PSCmdlet.ParameterSetName) {
      'Specification' {
        foreach ($ModuleToInstall in $Specification) {
          $isDuplicate = -not $ModulesToInstall.Add($ModuleToInstall)
          if ($isDuplicate) {
            Write-Warning "$ModuleToInstall was specified twice, skipping duplicate"
          }
        }
        break

      }
      'ModuleFastInfo' {
        foreach ($info in $ModuleFastInfo) {
          $installPlan.Add($info)
        }
        break
      }
      'Path' {
        $Paths = @()
        #Search for a spec file if a directory was provided
        if ('Directory' -in (Get-Item $Path).Attributes) {
          $Paths += Find-RequiredSpecFile -Path $Path
        } else {
          $Paths = $Path
        }
        foreach ($pathItem in $Paths) {
          $ModulesToInstall = ConvertFrom-RequiredSpec -RequiredSpecPath $pathItem -SpecFileType $SpecFileType
        }
      }
    }
  }

  end {
    trap {$PSCmdlet.ThrowTerminatingError($PSItem)}
    try {
      if (-not $installPlan) {
        if ($ModulesToInstall.Count -eq 0 -and $PSCmdlet.ParameterSetName -eq 'Specification') {
          Write-Verbose '🔎 No modules specified to install. Beginning SpecFile detection...'
          $modulesToInstall = if ($CI -and (Test-Path $CILockFilePath)) {
            Write-Debug "Found lockfile at $CILockFilePath. Using for specification evaluation and ignoring all others."
            ConvertFrom-RequiredSpec -RequiredSpecPath $CILockFilePath -SpecFileType $SpecFileType
            if ($Update) {
              Write-Verbose "-Update was specified but a lockfile was found. Ignoring -Update and using lockfile specification."
              $Update = $false
            }
          } else {
            $specFiles = Find-RequiredSpecFile $PWD -CILockFileHint $CILockFilePath
            if (-not $specFiles) {
              Write-Warning "No specfiles found in $PWD. Please ensure you have a .requires.json or .requires.psd1 file in the current directory, specify a path with -Path, or define specifications with the -Specification parameter to skip this search."
            }
            foreach ($specfile in $specFiles) {
              Write-Verbose "Found Specfile $specFile. Evaluating..."
              ConvertFrom-RequiredSpec -RequiredSpecPath $specFile -SpecFileType $SpecFileType
            }
          }
        }

        if (-not $ModulesToInstall) {
          throw [InvalidDataException]'No modules specifications found to evaluate.'
        }

        #If we do not have an explicit implementation plan, fetch it
        #This is done so that Get-ModuleFastPlan | Install-ModuleFastPlan and Install-ModuleFastPlan have the same flow.
        [ModuleFastInfo[]]$installPlan = if ($PSCmdlet.ParameterSetName -eq 'ModuleFastInfo') {
          $ModulesToInstall.ToArray()
        } else {
          Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status 'Plan' -PercentComplete 1
          $getPlanParams = @{
            Specification   = $ModulesToInstall
            HttpClient      = $httpClient
            Source          = $Source
            Update          = $Update
            PreRelease      = $Prerelease.IsPresent
            DestinationOnly = $DestinationOnly
            Destination     = $Destination
            Timeout         = $Timeout
            StrictSemVer    = $StrictSemVer
          }
          Get-ModuleFastPlan @getPlanParams
        }
      }

      if ($installPlan.Count -eq 0) {
        $planAlreadySatisfiedMessage = "`u{2705} $($ModulesToInstall.count) Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update"
        if ($WhatIfPreference) {
          Write-Host -fore DarkGreen $planAlreadySatisfiedMessage
        } else {
          Write-Verbose $planAlreadySatisfiedMessage
        }
        return
      }

      #Unless Plan was specified, run the process (WhatIf will also short circuit).
      #Plan is specified first so that WhatIf message will only show if Plan is not specified due to -or short circuit logic.
      if ($Plan -or -not (Approve-Action $Destination "Install $($installPlan.Count) Modules")) {
        if ($Plan) {
          Write-Verbose "📑 -Plan was specified. Returning a plan including $($installPlan.Count) Module Specifications"
        }
        #TODO: Separate planned installs and dependencies. Can probably do this with a dependency flag on the ModuleInfo item and some custom formatting.
        Write-Output $installPlan
      } else {
        Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status "Installing: $($installPlan.count) Modules" -PercentComplete 50

        $installHelperParams = @{
          ModuleToInstall   = $installPlan
          Destination       = $Destination
          CancellationToken = $cancelSource.Token
          HttpClient        = $httpClient
          Update            = $Update -or $PSCmdlet.ParameterSetName -eq 'ModuleFastInfo'
          ThrottleLimit     = $ThrottleLimit
        }
        $installedModules = Install-ModuleFastHelper @installHelperParams
        Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Completed
        Write-Verbose "`u{2705} All required modules installed! Exiting."
        if ($PassThru) {
          Write-Output $installedModules
        }
      }

      if ($CI) {
        #FIXME: If a package was already installed, it doesn't show up in this lockfile.
        Write-Verbose "Writing lockfile to $CILockFilePath"
        [Dictionary[string, string]]$lockFile = @{}
        $installPlan
        | ForEach-Object {
          $lockFile.Add($PSItem.Name, $PSItem.ModuleVersion)
        }

        $lockFile
        | ConvertTo-Json -Depth 2
        | Out-File -FilePath $CILockFilePath -Encoding UTF8
      }
    } finally {
      $cancelSource.Dispose()
    }
  }
}

function New-ModuleFastClient {
  param(
    [PSCredential]$Credential,
    [int]$Timeout = 30
  )
  Write-Debug 'Creating new ModuleFast HTTP Client. This should only happen once!'
  $ErrorActionPreference = 'Stop'
  #SocketsHttpHandler is the modern .NET 5+ default handler for HttpClient.

  $httpHandler = [SocketsHttpHandler]@{
    #The max connections are only in case we end up using HTTP/1.1 instead of HTTP/2 for whatever reason. HTTP/2 will only use one connection (but multiple streams) per the spec unless EnableMultipleHttp2Connections is specified
    MaxConnectionsPerServer        = 10
    #Reduce the amount of round trip confirmations by setting window size to 64MB. ModuleFast should primarily be used on reliable fast connections. Dynamic scaling will reduce this if needed.
    InitialHttp2StreamWindowSize   = 16777216
    AutomaticDecompression         = 'All'
  }

  $httpClient = [HttpClient]::new($httpHandler)
  $httpClient.BaseAddress = $Source
  #When in parallel some operations may take a significant amount of time to return
  $httpClient.Timeout = [TimeSpan]::FromSeconds($Timeout)

  #If a credential was provided, use it as a basic auth credential
  if ($Credential) {
    $httpClient.DefaultRequestHeaders.Authorization = ConvertTo-AuthenticationHeaderValue $Credential
  }

  #This user agent is important, it indicates to pwsh.gallery that we want dependency-only metadata
  #TODO: Do this with a custom header instead
  $userHeaderAdded = $httpClient.DefaultRequestHeaders.UserAgent.TryParseAdd('ModuleFast (github.com/JustinGrote/ModuleFast)')
  if (-not $userHeaderAdded) {
    throw 'Failed to add User-Agent header to HttpClient. This is a bug'
  }

  #This will multiplex all queries over a single connection, minimizing TLS setup overhead
  #Should also support HTTP/3 on newest PS versions
  $httpClient.DefaultVersionPolicy = [HttpVersionPolicy]::RequestVersionOrHigher
  #This should enable HTTP/3 on Win11 22H2+ (or linux with http3 library) and PS 7.2+
  [void][AppContext]::SetSwitch('System.Net.SocketsHttpHandler.Http3Support', $true)
  return $httpClient
}

function Get-ModuleFastPlan {
  <#
  .NOTES
  THIS COMMAND IS DEPRECATED AND WILL NOT RECEIVE PARAMETER UPDATES. Please use Install-ModuleFast -Plan instead.
  #>
  [CmdletBinding()]
  [OutputType([ModuleFastInfo[]])]
  param(
    #The module(s) to install. This can be a string, a ModuleSpecification, a hashtable with nuget version style (e.g. @{Name='test';Version='1.0'}), a hashtable with ModuleSpecification style (e.g. @{Name='test';RequiredVersion='1.0'}),
    [Alias('Name')]
    [Parameter(Position = 0, Mandatory, ValueFromPipeline)][ModuleFastSpec[]]$Specification,
    #The repository to scan for modules. TODO: Multi-repo support
    [string]$Source = 'https://pwsh.gallery/index.json',
    #Whether to include prerelease modules in the request
    [Switch]$Prerelease,
    #By default we use in-place modules if they satisfy the version requirements. This switch will force a search for all latest modules
    [Switch]$Update,
    [PSCredential]$Credential,
    [int]$Timeout = 30,
    [HttpClient]$HttpClient = $(New-ModuleFastClient -Credential $Credential -Timeout $Timeout),
    [int]$ParentProgress,
    [string]$Destination,
    [switch]$DestinationOnly,
    [CancellationToken]$CancellationToken,
    [switch]$StrictSemVer
  )

  BEGIN {
    trap {$PSCmdlet.ThrowTerminatingError($PSItem)}

    $ErrorActionPreference = 'Stop'
    [HashSet[ModuleFastSpec]]$modulesToResolve = @()

    #We use this token to cancel the HTTP requests if the user hits ctrl-C without having to dispose of the HttpClient.
    #We get a child so that a cancellation here does not affect any upstream commands
    $cancelTokenSource = $CancellationToken ? [CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken) : [CancellationTokenSource]::new()
    $CancellationToken = $cancelTokenSource.Token

    #We pass this splat to all our HTTP requests to cut down on boilerplate
    $httpContext = @{
      HttpClient        = $httpClient
      CancellationToken = $CancellationToken
    }
  }
  PROCESS {
    trap {$PSCmdlet.ThrowTerminatingError($PSItem)}

    foreach ($spec in $Specification) {
      if (-not $ModulesToResolve.Add($spec)) {
        Write-Warning "$spec was specified twice, skipping duplicate"
      }
    }
  }
  END {
    trap {$PSCmdlet.ThrowTerminatingError($PSItem)}

    try {
      # A deduplicated list of modules to install
      [HashSet[ModuleFastInfo]]$modulesToInstall = @{}

      # We use this as a fast lookup table for the context of the request
      [Dictionary[Task, ModuleFastSpec]]$taskSpecMap = @{}

      #We use this to track the tasks that are currently running
      #We dont need this to be ConcurrentList because we only manipulate it in the "main" runspace.
      [List[Task]]$currentTasks = @()

      #This is used to track the highest candidate if -Update was specified to force a remote lookup. If the candidate is still the most valid after remote lookup we can skip it without hitting disk to read the manifest again.
      [Dictionary[ModuleFastSpec, ModuleFastInfo]]$bestLocalCandidate = @{}

      foreach ($moduleSpec in $ModulesToResolve) {
        Write-Verbose "${moduleSpec}: Evaluating Module Specification"
        $findLocalParams = @{
          Update = $Update
          BestCandidate = ([ref]$bestLocalCandidate)
        }
        if ($DestinationOnly) { $findLocalParams.ModulePaths = $Destination }

        [ModuleFastInfo]$localMatch = Find-LocalModule @findLocalParams $moduleSpec
        if ($localMatch) {
          Write-Debug "${localMatch}: 🎯 FOUND satisfying version $($localMatch.ModuleVersion) at $($localMatch.Location). Skipping remote search."
          #TODO: Capture this somewhere that we can use it to report in the deploy plan
          continue
        }

        #If we get this far, we didn't find a manifest in this module path
        Write-Debug "${moduleSpec}: 🔍 No installed versions matched the spec. Will check remotely."

        $task = Get-ModuleInfoAsync @httpContext -Endpoint $Source -Name $moduleSpec.Name
        $taskSpecMap[$task] = $moduleSpec
        $currentTasks.Add($task)
      }

      [int]$tasksCompleteCount = 1
      [int]$resolveTaskCount = $currentTasks.Count -as [Int]
      do {
        #The timeout here allow ctrl-C to continue working in PowerShell
        #-1 is returned by WaitAny if we hit the timeout before any tasks completed
        $noTasksYetCompleted = -1
        [int]$thisTaskIndex = [Task]::WaitAny($currentTasks, 500)
        if ($thisTaskIndex -eq $noTasksYetCompleted) { continue }

        #The Plan whitespace is intentional so that it lines up with install progress using the compact format
        Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status "Plan: Resolving $tasksCompleteCount/$resolveTaskCount Module Dependencies" -PercentComplete ((($tasksCompleteCount / $resolveTaskCount) * 50) + 1)

        #TODO: This only indicates headers were received, content may still be downloading and we dont want to block on that.
        #For now the content is small but this could be faster if we have another inner loop that WaitAny's on content
        #TODO: Perform a HEAD query to see if something has changed

        $completedTask = $currentTasks[$thisTaskIndex]
        [ModuleFastSpec]$currentModuleSpec = $taskSpecMap[$completedTask]
        if (-not $currentModuleSpec) {
          throw 'Failed to find Module Specification for completed task. This is a bug.'
        }

        if ($currentModuleSpec.Guid -ne [Guid]::Empty) {
          Write-Warning "${currentModuleSpec}: A GUID constraint was found in the module spec. ModuleSpec will currently only verify GUIDs after the module has been installed, so a plan may not be accurate. It is not recommended to match modules by GUID in ModuleFast, but instead verify package signatures for full package authenticity."
        }

        Write-Debug "${currentModuleSpec}: Processing Response"
        # We use GetAwaiter so we get proper error messages back, as things such as network errors might occur here.
        try {
          $response = $completedTask.GetAwaiter().GetResult()
          | ConvertFrom-Json
          Write-Debug "${currentModuleSpec}: Received Response with $($response.Count) pages"
        } catch {
          $taskException = $PSItem.Exception.InnerException
          #TODO: Rewrite this as a handle filter
          if ($taskException -isnot [HttpRequestException]) { throw }
          [HttpRequestException]$err = $taskException
          if ($err.StatusCode -eq [HttpStatusCode]::NotFound) {
            throw [InvalidOperationException]"${currentModuleSpec}: module was not found in the $Source repository. Check the spelling and try again."
          }

          #All other cases
          $PSItem.ErrorDetails = "${currentModuleSpec}: Failed to fetch module $currentModuleSpec from $Source. Error: $PSItem"
          throw $PSItem
        }

        if (-not $response.count) {
          throw [InvalidDataException]"${currentModuleSpec}: invalid result received from $Source. This is probably a bug. Content: $response"
        }

        #If what we are looking for exists in the response, we can stop looking
        #TODO: Type the responses and check on the type, not the existence of a property.

        #TODO: This needs to be moved to a function so it isn't duplicated down in the "else" section below
        $pageLeaves = $response.items.items
        $pageLeaves | ForEach-Object {
          if ($PSItem.packageContent -and -not $PSItem.catalogEntry.packagecontent) {
            $PSItem.catalogEntry
            | Add-Member -NotePropertyName 'PackageContent' -NotePropertyValue $PSItem.packageContent
          }
        }

        $entries = $pageLeaves.catalogEntry

        #Get the highest version that satisfies the requirement in the inlined index, if possible
        $selectedEntry = if ($entries) {
          #Sanity Check for Modules
          if ('ItemType:Script' -in $entries[0].tags) {
            throw [NotImplementedException]"${currentModuleSpec}: Script installations are currently not supported."
          }

          [SortedSet[NuGetVersion]]$inlinedVersions = $entries.version

          foreach ($candidate in $inlinedVersions.Reverse()) {
            #Skip Prereleases unless explicitly requested
            if (($candidate.IsPrerelease -or $candidate.HasMetadata) -and -not ($currentModuleSpec.PreRelease -or $Prerelease)) {
              Write-Debug "${moduleSpec}: skipping candidate $candidate because it is a prerelease and prerelease was not specified either with the -Prerelease parameter, by specifying a prerelease version in the spec, or adding a ! on the module name spec to indicate prerelease is acceptable."
              continue
            }

            if ($currentModuleSpec.SatisfiedBy($candidate, $StrictSemVer)) {
              Write-Debug "${ModuleSpec}: Found satisfying version $candidate in the inlined index."
              $matchingEntry = $entries | Where-Object version -EQ $candidate
              if ($matchingEntry.count -gt 1) { throw 'Multiple matching Entries found for a specific version. This is a bug and should not happen' }
              $matchingEntry
              break
            }
          }
        }

        if ($selectedEntry.count -gt 1) { throw 'Multiple Entries Selected. This is a bug.' }
        #Search additional pages if we didn't find it in the inlined ones
        $selectedEntry ??= $(
          Write-Debug "${currentModuleSpec}: not found in inlined index. Determining appropriate page(s) to query"

          #If not inlined, we need to find what page(s) might have the candidate info we are looking for, starting with the highest numbered page first

          $pages = $response.items
          | Where-Object { -not $PSItem.items } #Get non-inlined pages
          | Where-Object {
            [VersionRange]$pageRange = [VersionRange]::new($PSItem.Lower, $true, $PSItem.Upper, $true, $null, $null)
            return $currentModuleSpec.Overlap($pageRange)
          }
          | Sort-Object -Descending { [NuGetVersion]$PSItem.Upper }

          if (-not $pages) {
            throw [InvalidOperationException]"${currentModuleSpec}: a matching module was not found in the $Source repository that satisfies the requested version constraints. You may need to specify -PreRelease or adjust your version constraints."
          }

          Write-Debug "${currentModuleSpec}: Found $(@($pages).Count) additional pages that might match the query: $($pages.'@id' -join ',')"

          #TODO: This is relatively slow and blocking, but we would need complicated logic to process it in the main task handler loop.
          #I really should make a pipeline that breaks off tasks based on the type of the response.
          #This should be a relatively rare query that only happens when the latest package isn't being resolved.

          #Start with the highest potentially matching page and work our way down until we find a match.
          foreach ($page in $pages) {
            $response = (Get-ModuleInfoAsync @httpContext -Uri $page.'@id').GetAwaiter().GetResult() | ConvertFrom-Json

            $pageLeaves = $response.items | ForEach-Object {
              if ($PSItem.packageContent -and -not $PSItem.catalogEntry.packagecontent) {
                $PSItem.catalogEntry
                | Add-Member -NotePropertyName 'PackageContent' -NotePropertyValue $PSItem.packageContent
              }
              $PSItem
            }

            $entries = $pageLeaves.catalogEntry

            #TODO: Dedupe as a function with above
            if ($entries) {
              [SortedSet[NuGetVersion]]$pageVersions = $entries.version

              foreach ($candidate in $pageVersions.Reverse()) {
                #Skip Prereleases unless explicitly requested
                if (($candidate.IsPrerelease -or $candidate.HasMetadata) -and -not ($currentModuleSpec.PreRelease -or $Prerelease)) {
                  Write-Debug "Skipping candidate $candidate because it is a prerelease and prerelease was not specified either with the -Prerelease parameter or with a ! on the module name."
                  continue
                }

                if ($currentModuleSpec.SatisfiedBy($candidate, $StrictSemVer)) {
                  Write-Debug "${currentModuleSpec}: Found satisfying version $candidate in the additional pages."
                  $matchingEntry = $entries | Where-Object version -EQ $candidate
                  if (-not $matchingEntry) { throw 'Multiple matching Entries found for a specific version. This is a bug and should not happen' }
                  $matchingEntry
                  break
                }
              }
            }

            #Candidate found, no need to process additional pages
            if ($matchingEntry) { break }
          }
        )

        if (-not $selectedEntry) {
          throw [InvalidOperationException]"${currentModuleSpec}: a matching module was not found in the $Source repository that satisfies the version constraints. You may need to specify -PreRelease or adjust your version constraints."
        }
        if (-not $selectedEntry.PackageContent) { throw "No package location found for $($selectedEntry.PackageContent). This should never happen and is a bug" }

        [ModuleFastInfo]$selectedModule = [ModuleFastInfo]::new(
          $selectedEntry.id,
          $selectedEntry.version,
          $selectedEntry.PackageContent
        )
        if ($moduleSpec.Guid -and $moduleSpec.Guid -ne [Guid]::Empty) {
          $selectedModule.Guid = $moduleSpec.Guid
        }

        #If -Update was specified, we need to re-check that none of the selected modules are already installed.
        #TODO: Persist state of the local modules found to this point so we don't have to recheck.
        if ($Update -and $bestLocalCandidate[$currentModuleSpec].ModuleVersion -eq $selectedModule.ModuleVersion) {
          Write-Debug "${selectedModule}: ✅ -Update was specified and the best remote candidate matches what is locally installed, so we can skip this module."
          #TODO: Fix the flow so this isn't stated twice
          [void]$taskSpecMap.Remove($completedTask)
          [void]$currentTasks.Remove($completedTask)
          $tasksCompleteCount++
          continue
        }

        #Check if we have already processed this item and move on if we have
        if (-not $modulesToInstall.Add($selectedModule)) {
          Write-Debug "$selectedModule already exists in the install plan. Skipping..."
          #TODO: Fix the flow so this isn't stated twice
          [void]$taskSpecMap.Remove($completedTask)
          [void]$currentTasks.Remove($completedTask)
          $tasksCompleteCount++
          continue
        }

        Write-Verbose "${selectedModule}: Added to install plan"

        # HACK: Pwsh doesn't care about target framework as of today so we can skip that evaluation
        # TODO: Should it? Should we check for the target framework and only install if it matches?
        $dependencyInfo = $selectedEntry.dependencyGroups.dependencies

        #Determine dependencies and add them to the pending tasks
        if ($dependencyInfo) {
          # HACK: I should be using the Id provided by the server, for now I'm just guessing because
          # I need to add it to the ComparableModuleSpec class
          [List[ModuleFastSpec]]$dependencies = $dependencyInfo | ForEach-Object {
            # Handle rare cases where range is not specified in the dependency
            [VersionRange]$range = [string]::IsNullOrWhiteSpace($PSItem.range) ?
            [VersionRange]::new() :
            [VersionRange]::Parse($PSItem.range)

            [ModuleFastSpec]::new($PSItem.id, $range)
          }
          Write-Debug "${currentModuleSpec}: has $($dependencies.count) additional dependencies: $($dependencies -join ', ')"

          # TODO: Where loop filter maybe
          [ModuleFastSpec[]]$dependenciesToResolve = $dependencies | Where-Object {
            $dependency = $PSItem
            # TODO: This dependency resolution logic should be a separate function
            # Maybe ModulesToInstall should be nested/grouped by Module Name then version to speed this up, as it currently
            # enumerates every time which shouldn't be a big deal for small dependency trees but might be a
            # meaninful performance difference on a whole-system upgrade.
            [HashSet[string]]$moduleNames = $modulesToInstall.Name
            if ($dependency.Name -notin $ModuleNames) {
              Write-Debug "$($dependency.Name): No modules with this name currently exist in the install plan. Resolving dependency..."
              return $true
            }

            $modulesToInstall
            | Where-Object Name -EQ $dependency.Name
            | Sort-Object ModuleVersion -Descending
            | ForEach-Object {
              if ($dependency.SatisfiedBy($PSItem.ModuleVersion, $StrictSemVer)) {
                Write-Debug "Dependency $dependency satisfied by existing planned install item $PSItem"
                return $false
              }
            }

            Write-Debug "Dependency $($dependency.Name) is not satisfied by any existing planned install items. Resolving dependency..."
            return $true
          }

          if (-not $dependenciesToResolve) {
            Write-Debug "$moduleSpec has no remaining dependencies that need resolving"
            continue
          }

          Write-Debug "Fetching info on remaining $($dependenciesToResolve.count) dependencies"

          # We do this here rather than populate modulesToResolve because the tasks wont start until all the existing tasks complete
          # TODO: Figure out a way to dedupe this logic maybe recursively but I guess a function would be fine too
          foreach ($dependencySpec in $dependenciesToResolve) {
            $findLocalParams = @{
              Update = $Update
              BestCandidate = ([ref]$bestLocalCandidate)
            }
            if ($DestinationOnly) { $findLocalParams.ModulePaths = $Destination }

            [ModuleFastInfo]$localMatch = Find-LocalModule @findLocalParams $dependencySpec
            if ($localMatch) {
              Write-Debug "FOUND local module $($localMatch.Name) $($localMatch.ModuleVersion) at $($localMatch.Location.AbsolutePath) that satisfies $moduleSpec. Skipping..."
              #TODO: Capture this somewhere that we can use it to report in the deploy plan
              continue
            } else {
              Write-Debug "No local modules that satisfies dependency $dependencySpec. Checking Remote..."
            }

            Write-Debug "${currentModuleSpec}: Fetching dependency $dependencySpec"
            #TODO: Do a direct version lookup if the dependency is a required version
            $task = Get-ModuleInfoAsync @httpContext -Endpoint $Source -Name $dependencySpec.Name
            $taskSpecMap[$task] = $dependencySpec
            #Used to track progress as tasks can get removed
            $resolveTaskCount++

            $currentTasks.Add($task)
          }
        }

        #Putting .NET methods in a try/catch makes errors in them terminating
        try {
          [void]$taskSpecMap.Remove($completedTask)
          [void]$currentTasks.Remove($completedTask)
          $tasksCompleteCount++
        } catch {
          throw
        }
      } while ($currentTasks.count -gt 0)

      if ($modulesToInstall) { return $modulesToInstall }
    } finally {
      #Cancel any outstanding tasks if unexpected error occurs
      $cancelTokenSource.Dispose()
    }
  }
}

function Clear-ModuleFastCache {
  <#
  .SYNOPSIS
  Clears the ModuleFast HTTP Cache. This is useful if you are expecting a newer version of a module to be available.
  #>
  Write-Debug "Flushing ModuleFast Request Cache"
  $SCRIPT:RequestCache.Dispose()
  $SCRIPT:RequestCache = [MemoryCache]::new('PowerShell-ModuleFast-RequestCache')
}

#endregion Public

#region Private

function Install-ModuleFastHelper {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ModuleFastInfo[]]$ModuleToInstall,
    [string]$Destination,
    [Parameter(Mandatory)][CancellationToken]$CancellationToken,
    [HttpClient]$HttpClient,
    [switch]$Update,
    [int]$ThrottleLimit,
    [int]$Timeout = 30
  )
  BEGIN {
    #We use this token to cancel the HTTP requests if the user hits ctrl-C without having to dispose of the HttpClient.
    #We get a child so that a cancellation here does not affect any upstream commands
    $cancelTokenSource = $CancellationToken ? [CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken) : [CancellationTokenSource]::new()
    $CancellationToken = $cancelTokenSource.Token
  }
  END {
    $ErrorActionPreference = 'Stop'

    try {
      #Used to keep track of context with Tasks, because we dont have "await" style syntax like C#
      [Dictionary[Task, hashtable]]$taskMap = @{}
      [List[Task[Stream]]]$streamTasks = foreach ($module in $ModuleToInstall) {
        $installPath = Join-Path $Destination $module.Name (Resolve-FolderVersion $module.ModuleVersion)
        #TODO: Do a get-localmodule check here
        $installIndicatorPath = Join-Path $installPath '.incomplete'
        if (Test-Path $installIndicatorPath) {
          Write-Warning "${module}: Incomplete installation found at $installPath. Will delete and retry."
          Remove-Item $installPath -Recurse -Force
        }

        if (Test-Path $installPath) {
          $existingManifestPath = try {
            Resolve-Path (Join-Path $installPath "$($module.Name).psd1") -ErrorAction Stop
          } catch [ActionPreferenceStopException] {
            throw "${module}: Existing module folder found at $installPath but the manifest could not be found. This is likely a corrupted or missing module and should be fixed manually."
          }

          #TODO: Dedupe all import-powershelldatafile operations to a function ideally
          $existingModuleMetadata = Import-ModuleManifest $existingManifestPath
          $existingVersion = [NugetVersion]::new(
            $existingModuleMetadata.ModuleVersion,
            $existingModuleMetadata.privatedata.psdata.prerelease
          )

          #Do a prerelease evaluation
          if ($module.ModuleVersion -eq $existingVersion) {
            if ($Update) {
              Write-Debug "${module}: Existing module found at $installPath and its version $existingVersion is the same as the requested version. -Update was specified so we are assuming that the discovered online version is the same as the local version and skipping this module installation."
              continue
            } else {
              throw [NotImplementedException]"${module}: Existing module found at $installPath and its version $existingVersion is the same as the requested version. This is probably a bug because it should have been detected by localmodule detection. Use -Update to override..."
            }
          }
          if ($module.ModuleVersion -lt $existingVersion) {
            #TODO: Add force to override
            throw [NotSupportedException]"${module}: Existing module found at $installPath and its version $existingVersion is newer than the requested prerelease version $($module.ModuleVersion). If you wish to continue, please remove the existing module folder or modify your specification and try again."
          } else {
            Write-Warning "${module}: Planned version $($module.ModuleVersion) is newer than existing prerelease version $existingVersion so we will overwrite."
            Remove-Item $installPath -Force -Recurse
          }
        }

        Write-Verbose "${module}: Downloading from $($module.Location)"
        if (-not $module.Location) {
          throw "${module}: No Download Link found. This is a bug"
        }

        $streamTask = $httpClient.GetStreamAsync($module.Location, $CancellationToken)
        $context = @{
          Module      = $module
          InstallPath = $installPath
        }
        $taskMap.Add($streamTask, $context)
        $streamTask
      }


      [List[Job2]]$installJobs = while ($streamTasks.count -gt 0) {
        $noTasksYetCompleted = -1
        [int]$thisTaskIndex = [Task]::WaitAny($streamTasks, 500)
        if ($thisTaskIndex -eq $noTasksYetCompleted) { continue }
        $thisTask = $streamTasks[$thisTaskIndex]
        $stream = $thisTask.GetAwaiter().GetResult()
        $context = $taskMap[$thisTask]
        $context.fetchStream = $stream
        $streamTasks.RemoveAt($thisTaskIndex)

        # This is a sync process and we want to do it in parallel, hence the threadjob
        Write-Verbose "$($context.Module): Extracting to $($context.installPath)"
        $installJob = Start-ThreadJob -ThrottleLimit $ThrottleLimit {
          param(
            [ValidateNotNullOrEmpty()]$stream = $USING:stream,
            [ValidateNotNullOrEmpty()]$context = $USING:context
          )
          process {
            try {
              $installPath = $context.InstallPath
              $installIndicatorPath = Join-Path $installPath '.incomplete'

              if (Test-Path $installIndicatorPath) {
                #FIXME: Output inside a threadjob is not surfaced to the user.
                Write-Warning "$($context.Module): Incomplete installation found at $installPath. Will delete and retry."
                Remove-Item $installPath -Recurse -Force
              }

              if (-not (Test-Path $context.InstallPath)) {
                New-Item -Path $context.InstallPath -ItemType Directory -Force | Out-Null
              }

              New-Item -ItemType File -Path $installIndicatorPath -Force | Out-Null

              #We are going to extract these straight out of memory, so we don't need to write the nupkg to disk
              $zip = [IO.Compression.ZipArchive]::new($stream, 'Read')
              [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $installPath)

              $manifestPath = Join-Path $installPath "$($context.Module.Name).psd1"

              # Try to read the manifest with a streamreader just to ModuleVersion.
              # This makes a glaring but reasonable assumption that the moduleVersion is not dynamic and has no newlines.
              # Much more performant than a full parse, as it will stop as soon as it hits moduleversion, perhaps at the
              # expense of more iops due to the readline vs reading the entire file at once
              $reader = [IO.StreamReader]::new($manifestPath)
              [Version]$moduleManifestVersion = $null
              try {
                while ($null -ne ($line = $reader.ReadLine())) {
                  if ($line -match '\s*ModuleVersion\s*=\s*[''"](?<version>.+?)[''"]') {
                    $moduleManifestVersion = $matches['version']
                    break
                  }
                }
              } finally {
                $reader.Close()
              }

              # Resolves an edge case where nuget packages are normalized in some package manages from 3.2.1.0 to 3.2.1
              if (-not $moduleManifestVersion) {
                Write-Warning "$($context.Module): Could not detect the module manifest version. This module may not install properly if it has trailing zeros in the version"
              } else {
                $installPathRoot = Split-Path $installPath
                $originalModuleVersion = Split-Path $installPath -Leaf
                if ($originalModuleVersion -ne $moduleManifestVersion)
                {
                    Write-Debug "$($context.Module): Module Manifest Version $moduleManifestVersion differs from package version $originalModuleVersion, moving..."

                    $newInstallPath = Join-Path $installPathRoot $moduleManifestVersion
                    [System.IO.Directory]::Move($installPath, $newInstallPath)

                    $installPath = $newInstallPath
                    $context.InstallPath = $installPath
                    $context.Module.ModuleVersion = [string]$moduleManifestVersion #Some System.Version don't cast right
                    $originalModuleVersion > (Join-Path $installPath '.originalModuleVersion')
                    $installIndicatorPath = Join-Path $installPath '.incomplete'
                } else {
                  Write-Debug "$($context.Module): Module Manifest version matches the expected version"
                }
              }

              if ($context.Module.Guid -and $context.Module.Guid -ne [Guid]::Empty) {
                Write-Debug "$($context.Module): GUID was specified in Module. Verifying manifest"
                $manifestPath = Join-Path $installPath "$($context.Module.Name).psd1"
                #FIXME: This should be using Import-ModuleManifest but it needs to be brought in via the ThreadJob context. This will fail if the module has a dynamic manifest.
                $manifest = Import-PowerShellDataFile $manifestPath
                if ($manifest.Guid -ne $context.Module.Guid) {
                  Remove-Item $installPath -Force -Recurse
                  throw [InvalidOperationException]"$($context.Module): The installed package GUID does not match what was in the Module Spec. Expected $($context.Module.Guid) but found $($manifest.Guid) in $($manifestPath). Deleting this module, please check that your GUID specification is correct, or otherwise investigate why the GUID is different."
                }
              }

              #FIXME: Output inside a threadjob is not surfaced to the user.
              Write-Debug "Cleanup Nuget Files in $installPath"
              if (-not $installPath) { throw 'ModuleDestination was not set. This is a bug, report it' }
              Get-ChildItem -Path $installPath | Where-Object {
                $_.Name -in '_rels', 'package', '[Content_Types].xml' -or
                $_.Name.EndsWith('.nuspec')
              } | Remove-Item -Force -Recurse

              Remove-Item $installIndicatorPath -Force
              return $context
            } finally {
              if ($zip) {$zip.Dispose()}
              if ($stream) {$stream.Dispose()}
            }
          }
        }
        $installJob
      }

      $installed = 0
      $installedModules = while ($installJobs.count -gt 0) {
        $ErrorActionPreference = 'Stop'
        $completedJob = $installJobs | Wait-Job -Any
        $completedJobContext = $completedJob | Receive-Job -Wait -AutoRemoveJob
        if (-not $installJobs.Remove($completedJob)) { throw 'Could not remove completed job from list. This is a bug, report it' }
        $installed++
        Write-Verbose "$($completedJobContext.Module): Installed to $($completedJobContext.InstallPath)"
        Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status "Install: $installed/$($ModuleToInstall.count) Modules" -PercentComplete ((($installed / $ModuleToInstall.count) * 50) + 50)
        $completedJobContext.Module.Location = $completedJobContext.InstallPath
        #Output the module for potential future passthru
        $completedJobContext.Module
      }

      if ($PassThru) {
        return $installedModules
      }

    } finally {
      $cancelTokenSource.Dispose()
      if ($installJobs) {
        try {
          $installJobs | Remove-Job -Force -ErrorAction SilentlyContinue
        } catch {
          #Suppress this error because it is likely that the job was already removed
          if ($PSItem -notlike '*because it is a child job*') {throw}
        }
      }
    }
  }
}

function Import-ModuleManifest {
  <#
  .SYNOPSIS
  Imports a module manifest from a path, and can handle some limited dynamic module manifest formats.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)][string]$Path
  )

  try {
    Import-PowerShellDataFile $Path -ErrorAction Stop
  } catch [InvalidOperationException] {
    if ($PSItem.Exception.Message -notlike '*Cannot generate a PowerShell object for a ScriptBlock evaluating dynamic expressions*') {throw}

    Write-Debug "$Path is a Manifest with dynamic expressions. Attempting to safe evaluate..."
    #Inspiration from: https://github.com/PowerShell/PSResourceGet/blob/0a1836a4088ab0f4f13a4638fa8cd0f571c24140/src/code/Utils.cs#L1219
    $manifest = [ScriptBlock]::Create((Get-Content $Path -Raw))

    $manifest.CheckRestrictedLanguage(
      [list[string]]::new(),
      [list[string]]@('PSEdition','PSScriptRoot'),
      $true
    )
    return $manifest.InvokeReturnAsIs();
  }
}

function ConvertFrom-PSDepend {
  [OutputType([ModuleFastSpec[]])]
  param(
    [hashtable]$PSDependManifest
  )

  $initialSpec = [ordered]@{}

  if ($PSDependManifest.ContainsKey('PSDependOptions')) {
    Write-Debug 'PSDepend Parse: PSDependOptions detected. Removing...'
    $options = $PSDependManifest['PSDependOptions']
    if ($options.DependencyType) {
      throw [NotSupportedException]"PSDepend Parse: Top-Level DependencyType in PSDependOptions is not currently supported."
    }
    if ($options.Target) {
      Write-Warning "PSDepend Parse: Target in PSDependOptions is not currently supported and will be ignored. Ensure you have -Destination $($options.Target) specified on the Install-ModuleFast command."
    }
    $PSDependManifest.Remove('PSDependOptions')
  }

  foreach ($key in $PSDependManifest.Keys) {
    $value = $PSDependManifest[$key]

    if ($key -isnot [string]) {
      throw [InvalidDataException]"PSDepend Parse: Manifest is invalid. Keys must be strings. Found $key $($key.GetType().FullName)"
    }

    if ($key -like '*/*') {
      Write-Debug "PSDepend Parse: Skipping Unsupported GitHub module $key"
      continue
    }

    if ($key -match '^(.+)::(.+)$') {
      if ($matches[0] -ne 'PSGalleryModule') {
        Write-Debug "PSDepend Parse: Skipping $key because its extended type is not PSGalleryModule"
        continue
      } else {
        Write-Debug "PSDepend Parse: Adding $key $value)"
        $initialSpec[$matches[1]] = $value
        continue
      }
    } elseif ($value -is [string]) {
      #If the key doesn't have any special formats and the value is a string, we can assume it is a direct "shorthand" specification
      $initialSpec[$key] = $value
      continue
    }

    #At this point there should only be PSDepend "Extended" Syntax objects
    if ($value -isnot [hashtable]) {
      throw [NotSupportedException]'PSDepend Parse: Value target must be a string or hashtable'
    }

    if ($value.DependencyType -ne 'PSGalleryModule') {
      Write-Debug "PSDepend Parse: Skipping $key because its extended DependencyType is not PSGalleryModule"
      continue
    }

    if ($value.Parameters.Repository) {
      Write-Warning "PSDepend Parse: Repository specification detected for $key. This is not currently supported and will use the default Source for now."
    }

    $version = $value.Version ?? 'latest'

    #TODO: Repository support
    if (-not $value.Name) {
      Write-Debug 'PSDepend Parse: Skipping $key because no Name property was specified'
    }

    if ($value.Parameters.AllowPrerelease) {
      Write-Debug "PSDepend Parse: Prerelease detected for $key"
      $value.Name = "!$($value.Name)"
    }

    Write-Debug "PSDepend Parse: Adding $key extended module name $($value.Name) $version"
    $initialSpec[$value.Name] = $version
  }

  foreach ($entry in $initialspec.GetEnumerator()) {
    if ($entry.Value -eq 'latest') {
      [ModuleFastSpec]::new($entry.Key)
    } else {
      [ModuleFastSpec]::new($entry.Key, $entry.Value)
    }
  }
}

function ConvertFrom-PSResourceGet {
  [OutputType([ModuleFastSpec[]])]
  param(
    [hashtable]$PSDependManifest
  )

  $initialSpec = [ordered]@{}
  foreach ($key in $PSDependManifest.Keys) {
    $value = $PSDependManifest[$key]

    if ($key -isnot [string]) {
      throw [InvalidDataException]"PSResourceGet Parse: Manifest is invalid. Keys must be strings. Found $key $($key.GetType().FullName)"
    }

    if ($value -is [string]) {
      $initialSpec[$key] = $value
      continue
    }

    #At this point there should only be PSDepend "Extended" Syntax objects
    if ($value -isnot [hashtable]) {throw [NotSupportedException]'PSResourceGet Parse: Value target must be a string or hashtable'}

    $version = $value.Version ?? 'latest'

    if ($value.prerelease) {
      Write-Debug "PSResourceGet Parse: Prerelease detected for $key"
      $key = "!$key"
    }

    if ($value.Repository) {
      Write-Warning "PSResourceGet Parse: Repository specification detected for $key. This is not currently supported and will use the default Source for now."
    }

    Write-Debug "PSResourceGet Parse: Adding $key extended module name $key $version"
    $initialSpec[$key] = $version
  }

  foreach ($entry in $initialspec.GetEnumerator()) {
    if ($entry.Value -eq 'latest') {
      [ModuleFastSpec]::new($entry.Key)
    } else {
      $version = $entry.Value

      #HACK: This handles a PSResourceGet/RequiresModule quirk where '1.0.5' is meant to be a specific version, not a minimum version which is what the NuGet version spec defines it as.
      # https://learn.microsoft.com/en-us/nuget/concepts/package-versioning?tabs=semver20sort
      if ($version.StartsWith('[') -or $version.StartsWith('(') -or $version.Contains('*')) {
        $version = [VersionRange]::Parse($entry.Value)
      }

      [ModuleFastSpec]::new($entry.Key, $version)
    }
  }
}

#endregion Private

#region Classes

enum SpecFileType {
  AutoDetect
  ModuleFast
  PSResourceGet #Note: RequiredModules seems to be semantically close enough to PSResourceGet to use the same parser
  PSDepend
}

#This is a module construction helper to create "getters" in classes. The getters must be defined as a static hidden class prefixed with Get_ (case sensitive) and take a single parameter of the PSObject type that will be an instance of the class object for you to act on. Place this in your class constructor to automatically add the getters to the class.
function Add-Getters ([Parameter(Mandatory, ValueFromPipeline)][Type]$Type) {
  $Type.GetMethods([BindingFlags]::Static -bor [BindingFlags]::Public)
  | Where-Object name -CLike 'Get_*'
  | Where-Object { $_.GetCustomAttributes([HiddenAttribute]) }
  | Where-Object {
    $params = $_.GetParameters()
    $params.count -eq 1 -and $params[0].ParameterType -eq [PSObject]
  }
  | ForEach-Object {
    Update-TypeData -TypeName $Type.FullName -MemberType CodeProperty -MemberName $($_.Name -replace 'Get_', '') -Value $PSItem -Force
  }
}

#Information about a module, whether local or remote
[NoRunspaceAffinity()]
class ModuleFastInfo: IComparable {
  [string]$Name
  #Sometimes the module version is not the same as the folder version, such as in the case of prerelease versions
  [NuGetVersion]$ModuleVersion
  #Path to the module, either local or remote
  [uri]$Location
  #TODO: This should be a getter
  [boolean]$IsLocal
  [Guid]$Guid = [Guid]::Empty

  ModuleFastInfo([string]$Name, [NuGetVersion]$ModuleVersion, [Uri]$Location) {
    $this.Name = $Name
    $this.ModuleVersion = $ModuleVersion
    $this.Location = $Location
    $this.IsLocal = $Location.IsFile
  }

  static hidden [Version]Get_Prerelease([bool]$i) {
    return $i.ModuleVersion.IsPrerelease -or $i.ModuleVersion.HasMetadata
  }

  #region ImplicitBehaviors
  # Implement an op_implicit convert to modulespecification
  static [ModuleSpecification]op_Implicit([ModuleFastInfo]$moduleFastInfo) {
    return [ModuleSpecification]::new(@{
        ModuleName      = $moduleFastInfo.Name
        RequiredVersion = $moduleFastInfo.ModuleVersion.Version
      })
  }

  [string] ToString() {
    return "$($this.Name)($($this.ModuleVersion))"
  }
  [string] ToUniqueString() {
    return "$($this.Name)-$($this.ModuleVersion)-$($this.Location)"
  }

  [int] GetHashCode() {
    return $this.ToUniqueString().GetHashCode()
  }

  [bool] Equals($other) {
    return $this.GetHashCode() -eq $other.GetHashCode()
  }

  [int] CompareTo($other) {
    return $(
      switch ($true) {
      ($other -isnot 'ModuleFastInfo') {
          $this.ToUniqueString().CompareTo([string]$other); break
        }
      ($this -eq $other) { 0; break }
      ($this.Name -ne $other.Name) { $this.Name.CompareTo($other.Name); break }
        default {
          $this.ModuleVersion.CompareTo($other.ModuleVersion)
        }
      }
    )
  }

  static hidden [bool]Get_Prerelease([PSObject]$i) {
    return $i.ModuleVersion.IsPrerelease -or $i.ModuleVersion.HasMetadata
  }

  #endregion ImplicitBehaviors
}

$ModuleFastInfoTypeData = @{
  DefaultDisplayPropertySet = 'Name', 'ModuleVersion', 'Location'
  DefaultKeyPropertySet     = 'Name', 'ModuleVersion', 'Location'
  SerializationMethod       = 'SpecificProperties'
  PropertySerializationSet  = 'Name', 'ModuleVersion', 'Location'
  SerializationDepth        = 0
}
[ModuleFastInfo] | Add-Getters
Update-TypeData -TypeName ModuleFastInfo @ModuleFastInfoTypeData -Force
Update-TypeData -TypeName Nuget.Versioning.NugetVersion -SerializationMethod String -Force


[NoRunspaceAffinity()]
class ModuleFastSpec {
  #These properties are effectively read only thanks to some getter wizardy

  #Name of the Module to Download
  hidden [string]$_Name
  static hidden [string]Get_Name([PSObject]$i) { return $i._Name }

  #Unique ID of the module. This is optional but detects the rare corruption case if two modules have the same name and version but different GUIDs
  hidden [guid]$_Guid
  static hidden [guid]Get_Guid([PSObject]$i) { return $i._Guid }

  #NuGet Version Range that specifies what Versions are acceptable. This can be specified as Nuget Version Syntax string
  hidden [VersionRange]$_VersionRange
  static hidden [VersionRange]Get_VersionRange([PSObject]$i) { return $i._VersionRange }

  #A flag to indicate if prerelease should be included if the name had ! specified (this is done in the constructor)
  hidden [bool]$_PreReleaseName
  static hidden [bool]Get_PreRelease([PSObject]$i) {
    return $i._VersionRange.MinVersion.IsPrerelease -or
    $i._VersionRange.MaxVersion.IsPrerelease -or
    $i._VersionRange.MinVersion.HasMetadata -or
    $i._VersionRange.MaxVersion.HasMetadata -or
    $i._PreReleaseName
  }

  static hidden [NugetVersion]Get_Min([PSObject]$i) { return $i._VersionRange.MinVersion }
  static hidden [NugetVersion]Get_Max([PSObject]$i) { return $i._VersionRange.MaxVersion }
  static hidden [NugetVersion]Get_Required([PSObject]$i) {
    if ($i.Min -eq $i.Max) {
      return $i.Min
    } else {
      return $null
    }
  }

  #ModuleSpecification Compatible Getters
  static hidden [Version]Get_RequiredVersion([PSObject]$i) {
    return $i.Required.Version
  }
  static hidden [Version]Get_Version([PSObject]$i) { return $i.Min.Version }
  static hidden [Version]Get_MaximumVersion([PSObject]$i) { return $i.Max.Version }

  #Constructors
  ModuleFastSpec([string]$Name, [string]$RequiredVersion) {
    $this.Initialize($Name, "[$RequiredVersion]", [guid]::Empty)
  }

  ModuleFastSpec([string]$Name, [string]$RequiredVersion, [string]$Guid) {
    $this.Initialize($Name, "[$RequiredVersion]", $Guid)
  }

  ModuleFastSpec([string]$Name, [VersionRange]$RequiredVersion) {
    $this.Initialize($Name, $RequiredVersion, [guid]::Empty)
  }

  ModuleFastSpec([ModuleSpecification]$ModuleSpec) {
    $this.Initialize($ModuleSpec)
  }

  ModuleFastSpec([ModuleFastInfo]$ModuleFastInfo) {
    $RequiredVersion = [VersionRange]::Parse("[$($ModuleFastInfo.ModuleVersion)]")
    $this.Initialize($ModuleFastInfo.Name, $requiredVersion, [guid]::Empty)
  }

  ModuleFastSpec([string]$Name) {
    #Used as a reference handle for TryParse
    [ModuleSpecification]$moduleSpec = $null

    switch ($true) {
      #Handles a string representation of a modulespecification hashtable
      ([ModuleSpecification]::TryParse($Name, [ref]$moduleSpec)) {
        $this.Initialize($moduleSpec)
        break
      }
      #There should be no more @{ after the string representation so end here if not parseable
      ($Name.contains('@{')) {
        throw [ArgumentException]"Cannot convert $Name to a ModuleFastSpec, it does not confirm to the ModuleSpecification syntax but has '@{' in the string."
      }
      ($Name.contains('>=')) {
        $moduleName, [NugetVersion]$lower = $Name.Split('>=')
        $this.Initialize($moduleName, $lower, [guid]::Empty)
        break
      }
      ($Name.contains('<=')) {
        $moduleName, [NugetVersion]$upper = $Name.Split('<=')
        $this.Initialize($moduleName, [VersionRange]::Parse("(,$upper]"), [guid]::Empty)
        break
      }
      ($Name.contains('=')) {
        $moduleName, $exactVersion = $Name.Split('=')
        $this.Initialize($moduleName, [VersionRange]::Parse("[$exactVersion]"), [guid]::Empty)
        break
      }
      #NuGet Version Syntax for this one
      ($Name.contains(':')) {
        $moduleName, $range = $Name.Split(':')
        $this.Initialize($moduleName, [VersionRange]::Parse($range), [guid]::Empty)
        break
      }

      ($Name.contains('>')) {
        $moduleName, [NugetVersion]$lowerExclusive = $Name.Split('>')
        $this.Initialize($moduleName, [VersionRange]::Parse("($lowerExclusive,]"), [guid]::Empty)
        break
      }
      ($Name.contains('<')) {
        $moduleName, [NugetVersion]$upperExclusive = $Name.Split('<')
        $this.Initialize($moduleName, [VersionRange]::Parse("(,$upperExclusive)"), [guid]::Empty)
        break
      }
      default {
        $this.Initialize($Name, $null, [guid]::Empty)
      }
    }
  }

  ModuleFastSpec([System.Collections.IDictionary]$ModuleSpec) {
    #TODO: Additional formats
    [ModuleSpecification]$ModuleSpec = [ModuleSpecification]::new($ModuleSpec)
    $this.Initialize($ModuleSpec)
  }

  # This is our fallback case when an object is supplied
  ModuleFast([object]$UnsupportedObject) {
    throw [NotSupportedException]"Cannot convert $($UnsupportedObject.GetType().FullName) to a ModuleFastSpec, please ensure you provided the correct type of object"
  }


  #TODO: Generic Hashtable/IDictionary constructor for common types

  #HACK: A helper because we can't do constructor chaining in PowerShell
  #https://stackoverflow.com/questions/44413206/constructor-chaining-in-powershell-call-other-constructors-in-the-same-class
  hidden Initialize([string]$Name, [VersionRange]$Range, [guid]$Guid) {
    #HACK: The nulls here are just to satisfy the ternary operator, they go off into the ether and arent returned or used
    if (-not $Name) { throw 'Name is required' }
    # Strip ! from the beginning or end of the name
    $TrimmedName = $Name.Trim('!')
    if ($TrimmedName -ne $Name) {
      Write-Debug "ModuleSpec $TrimmedName had prerelease identifier ! specified. Will include Prerelease modules"
      $this._PreReleaseName = $true
    }

    $this._Name = $TrimmedName
    $this._VersionRange = $Range ?? [VersionRange]::new()
    $this._Guid = $Guid ?? [Guid]::Empty
  }

  hidden Initialize([ModuleSpecification]$ModuleSpec) {
    [string]$Min = $ModuleSpec.RequiredVersion ?? $ModuleSpec.Version
    [string]$Max = $ModuleSpec.RequiredVersion ?? $ModuleSpec.MaximumVersion
    $guid = $ModuleSpec.Guid ?? [Guid]::Empty
    $range = [VersionRange]::new(
      [String]::IsNullOrEmpty($Min) ? $null : $Min,
      $true, #Inclusive
      [String]::IsNullOrEmpty($Max) ? $null : $Max,
      $true, #Inclusive
      $null,
      "ModuleSpecification: $ModuleSpec"
    )

    $this.Initialize($ModuleSpec.Name, $range, $guid)
  }

  #region Methods

  [bool] SatisfiedBy([version]$Version) {
    return $this.SatisfiedBy([NuGetVersion]::new($Version, $false))
  }
  [bool] SatisfiedBy([version]$Version, [bool]$strictSemVer) {
    return $this.SatisfiedBy([NuGetVersion]::new($Version, $strictSemVer))
  }

  [bool] SatisfiedBy([NugetVersion]$Version) {
    return $this.SatisfiedBy($Version, $false)
  }

  #strictSemVer means [1.0.0,2.0.0) will match 2.0.0-alpha1. Most people don't want this.
  [bool] SatisfiedBy([NugetVersion]$Version, [bool]$strictSemVer) {
    $range = $this._VersionRange
    $strictSatisfies = $range.IsFloating ?
      $range.Float.Satisfies($Version) :
      $range.Satisfies($Version)

    if ($strictSemVer) {
      return $strictSatisfies
    }

    if (-not $range.MaxVersion) {return $strictSatisfies}
    $max = $range.MaxVersion
    $min = $range.MinVersion

    if (
      #Example: Version is 2.0.0-alpha1 and the spec is module:[1.0.0,2.0.0)
      $Version.IsPrerelease -and
      -not $range.IsMaxInclusive -and
      -not $max.IsPrerelease -and
      ($max.Major -eq $Version.Major) -and
      ($max.Minor -eq $Version.Minor) -and
      ($max.Patch -eq $Version.Patch)
      #If the minimum matches the maximum and has a prerelease, that means it's a range like (3.0.0-alpha,3.0.0-beta and we want strict matching)
    )
    {
      #In a special case like (3.0.0-alpha,3.0.0-beta) where the min and max are the same version, we want normal strict semver behavior
      if (
        $min -and
        $min.Major -eq $max.Major -and
        $min.Minor -eq $max.Minor -and
        $min.Patch -eq $max.Patch -and
        $min.IsPrerelease
      ) {
        Write-Debug "ModuleFastSpec: $this is being compared to $Version. It was not excluded because the min matches the max and both are prereleases, so normal behavior occured."
        return $strictSatisfies
      }

      Write-Verbose "ModuleFastSpec: $this is typically satisfied by $Version, but this prerelease of the exclusive maximum version specification was ignored for ease of use. Specify -StrictSemVer to allow pre-releases of excluded versions."
      return $false
    }

    #Last resort is to use strict matching
    return $strictSatisfies
  }

  [bool] Overlap([ModuleFastSpec]$other) {
    return $this.Overlap($other._VersionRange)
  }

  [bool] Overlap([VersionRange]$other) {
    [List[VersionRange]]$ranges = @($this._VersionRange, $other)
    $subset = [VersionRange]::CommonSubset($ranges)
    #If the subset has an explicit version of 0.0.0, this means there was no overlap.
    return '(0.0.0, 0.0.0)' -ne $subset
  }


  #endregion Methods

  #region InterfaceImplementations

  #IEquatable
  #BUG: We cannot implement IEquatable directly because we need to self-reference ModuleFastSpec before it exists.
  #We can however just add Equals() method

  #Implementation of https://learn.microsoft.com/en-us/dotnet/api/system.iequatable-1.equals
  [bool]Equals($other) {
    return $this.GetHashCode() -eq $other.GetHashCode()
  }
  #end IEquatable

  [string] ToString() {
    $guid = $this._Guid -ne [Guid]::Empty ? " [$($this._Guid)]" : ''
    $versionRange = $this._VersionRange.ToString() -eq '(, )' ? '' : " $($this._VersionRange)"
    if ($this._VersionRange.MaxVersion -and $this._VersionRange.MaxVersion -eq $this._VersionRange.MinVersion) {
      $versionRange = "($($this._VersionRange.MinVersion))"
    }
    return "$($this._Name)$guid$versionRange"
  }
  [int] GetHashCode() {
    return $this.ToString().GetHashCode()
  }

  #IComparable
  #Implementation of https://learn.microsoft.com/en-us/dotnet/api/system.icomparable-1.equals
  [int]CompareTo($other) {
    if ($this.Equals($other)) { return 0 }
    if ($other -is [ModuleFastSpec]) {
      $other = $other._VersionRange
    }

    [NuGetVersion]$version = if ($other -is [VersionRange]) {
      if (-not $this.IsRequiredVersion($other)) {
        throw [NotSupportedException]"ModuleFastSpec $this has a version range, it must be a single required version e.g. '[1.5.0]'"
      }
      $other.MaxVersion
    } else {
      $other
    }

    $thisVersion = $this._VersionRange

    if ($thisVersion.Satisfies($Version)) { return 0 }
    if ($thisVersion.MinVersion -gt $Version) { return 1 }
    if ($thisVersion.MaxVersion -lt $Version) { return -1 }
    throw 'Could not compare. This should not happen and is a bug'
    return 0
  }

  hidden [bool]IsRequiredVersion([VersionRange]$Version) {
    return $Version.MinVersion -ne $Version.MaxVersion -or
    -not $Version.HasLowerAndUpperBounds -or
    -not $Version.IsMinInclusive -or
    -not $Version.IsMaxInclusive
  }

  #end IComparable

  #endregion InterfaceImplementations

  #region ImplicitConversions
  static [ModuleSpecification] op_Implicit([ModuleFastSpec]$moduleFastSpec) {
    $moduleSpecProperties = @{
      ModuleName = $moduleFastSpec.Name
    }
    if ($moduleFastSpec.Guid -ne [Guid]::Empty) {
      $moduleSpecProperties.Guid = $moduleFastSpec.Guid
    }
    if ($moduleFastSpec.Required) {
      [version]$version = $null
      [version]::TryParse($moduleFastSpec.Required, [ref]$version) | Out-Null
      $moduleSpecProperties.RequiredVersion = $moduleFastSpec.Required.Version
    } elseif ($moduleSpecProperties.Min -or $moduleSpecProperties.Max) {
      $moduleSpecProperties.ModuleVersion = $moduleFastSpec.Min.Version
      $moduleSpecProperties.MaximumVersion = $moduleFastSpec.Max.Version
    } else {
      $moduleSpecProperties.ModuleVersion = [Version]'0.0'
    }

    return [ModuleSpecification]$moduleSpecProperties
  }

  #endregion ImplicitConversions
}
[ModuleFastSpec] | Add-Getters

#endRegion Classes

#region Helpers

#This is used as a simple caching mechanism to avoid multiple simultaneous fetches for the same info. For example, Az.Accounts. It will persist for the life of the PowerShell session
[MemoryCache]$SCRIPT:RequestCache = [MemoryCache]::new('PowerShell-ModuleFast-RequestCache')
function Get-ModuleInfoAsync {
  [CmdletBinding()]
  [OutputType([Task[String]])]
  param (
    # The name of the module to search for
    [Parameter(Mandatory, ParameterSetName = 'endpoint')][string]$Name,
    # The URI of the nuget v3 repository base, e.g. https://pwsh.gallery/index.json
    [Parameter(Mandatory, ParameterSetName = 'endpoint')]$Endpoint,
    # The path we are calling for the registration.
    [Parameter(ParameterSetName = 'endpoint')][string]$Path = 'index.json',

    #The direct URI to the registration endpoint
    [Parameter(Mandatory, ParameterSetName = 'uri')][string]$Uri,

    [Parameter(Mandatory)][HttpClient]$HttpClient,
    [Parameter(Mandatory)][CancellationToken]$CancellationToken
  )

  if (-not $Uri) {
    $ModuleId = $Name

    #This call should be cached by httpclient after first attempt to speed up future calls
    $endpointTask = $SCRIPT:RequestCache[$Endpoint]

    if ($endpointTask) {
      Write-Debug "REQUEST CACHE HIT for Registration Index $Endpoint"
    } else {
      Write-Debug ('{0}fetch registration index from {1}' -f ($ModuleId ? "${ModuleId}: " : ''), $Endpoint)
      $endpointTask = $HttpClient.GetStringAsync($Endpoint, $CancellationToken)
      $SCRIPT:RequestCache[$Endpoint] = $endpointTask
    }

    $registrationIndex = $endpointTask.GetAwaiter().GetResult()

    $registrationBase = $registrationIndex
    | ConvertFrom-Json
    | Select-Object -ExpandProperty resources
    | Where-Object {
      $_.'@type' -match 'RegistrationsBaseUrl'
    }
    | Sort-Object -Property '@type' -Descending
    | Select-Object -ExpandProperty '@id' -First 1

    $Uri = "$($registrationBase -replace '/$','')/$($ModuleId.ToLower())/$Path"
  }

  $requestTask = $SCRIPT:RequestCache[$Uri]

  if ($requestTask) {
    Write-Debug "REQUEST CACHE HIT for $Uri"
    #HACK: We need the task to be a unique reference for the context mapping that occurs later on, so this is an easy if obscure way to "clone" the task using PowerShell.
    $requestTask = [Task]::WhenAll($requestTask)
  } else {
    Write-Debug ('{0}fetch info from {1}' -f ($ModuleId ? "${ModuleId}: " : ''), $uri)
    $requestTask = $HttpClient.GetStringAsync($uri, $CancellationToken)
    $SCRIPT:RequestCache[$Uri] = $requestTask
  }
  return $requestTask
}

function Add-DestinationToPSModulePath {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    <#Category#>'PSAvoidUsingDoubleQuotesForConstantString', <#CheckId#>$null, Scope = 'Function',
    Justification = 'Using string replacement so some double quotes with a constant are deliberate'
  )]

  <#
	.SYNOPSIS
	Adds an existing PowerShell Modules path to the current session as well as the profile
	#>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  param(
    [Parameter(Mandatory)][string]$Destination,
    [switch]$NoProfileUpdate
  )
  $ErrorActionPreference = 'Stop'
  $Destination = Resolve-Path $Destination #Will error if it doesn't exist

  # Check if the destination is in the PSModulePath. For a default setup this should basically always be true for Mac/Linux
  [string[]]$modulePaths = $env:PSModulePath.split([Path]::PathSeparator)
  if ($Destination -in $modulePaths) {
    Write-Debug "Destination '$Destination' is already in the PSModulePath, we will assume it is already configured correctly"
    return
  }

  # Generally we only get this far on Windows where the default CurrentUser is in Documents
  Write-Verbose "Updating PSModulePath to include $Destination"
  $env:PSModulePath = $Destination, $env:PSModulePath -join [Path]::PathSeparator

  if ($NoProfileUpdate) {
    Write-Debug 'Skipping updating the profile because -NoProfileUpdate was specified'
    return
  }

  #TODO: Support other profiles?
  $myProfile = $profile.CurrentUserAllHosts

  if (-not (Test-Path $myProfile)) {
    if (-not (Approve-Action $myProfile "Allow ModuleFast to work by creating a profile at $myProfile.")) { return }
    Write-Verbose 'User All Hosts profile not found, creating one.'
    New-Item -ItemType File -Path $myProfile -Force | Out-Null
  }

  #Prepare a relative destination if possible using Path.GetRelativePath
  foreach ($basePath in [environment]::GetFolderPath('LocalApplicationData'), $Home) {
    $relativeDestination = [Path]::GetRelativePath($basePath, $Destination)
    if ($relativeDestination -ne $Destination) {
      [string]$newDestination = '$([environment]::GetFolderPath(''LocalApplicationData''))' +
      [Path]::DirectorySeparatorChar +
      $relativeDestination
      Write-Verbose "Using relative path $newDestination instead of '$Destination' in profile"
      $Destination = $newDestination
      break
    }
  }
  Write-Verbose 'Checked for relative destination'

  [string]$profileLine = {if ("##DESTINATION##" -notin ($env:PSModulePath.split([IO.Path]::PathSeparator))) { $env:PSModulePath = "##DESTINATION##" + $([IO.Path]::PathSeparator + $env:PSModulePath) } <#Added by ModuleFast. DO NOT EDIT THIS LINE. If you do not want this, add -NoProfileUpdate to Install-ModuleFast or add the default destination to your powershell.config.json or to your PSModulePath another way.#> }

  #We can't use string formatting because of the braces already present
  $profileLine = $profileLine -replace '##DESTINATION##', $Destination

  if ((Get-Content -Raw $myProfile) -notmatch [Regex]::Escape($ProfileLine)) {
    if (-not (Approve-Action $myProfile "Allow ModuleFast to work by adding $Destination to your PSModulePath on startup by appending to your CurrentUserAllHosts profile. If you do not want this, add -NoProfileUpdate to Install-ModuleFast or add the specified destination to your powershell.config.json or to your PSModulePath another way.")) { return }
    Write-Verbose "Adding $Destination to profile $myProfile"
    Add-Content -Path $myProfile -Value "`n`n"
    Add-Content -Path $myProfile -Value $ProfileLine
  } else {
    Write-Verbose "PSModulePath $Destination already in profile, skipping..."
  }
}

function Find-LocalModule {
  [OutputType([ModuleFastInfo])]
  <#
	.SYNOPSIS
	Searches local PSModulePath repositories for the first module that satisfies the ModuleSpec criteria
	#>
  param(
    [Parameter(Mandatory)][ModuleFastSpec]$ModuleSpec,
    [string[]]$ModulePaths = $($env:PSModulePath.Split([Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)),
    [Switch]$Update,
    [ref]$BestCandidate
  )
  $ErrorActionPreference = 'Stop'

  if (-not $ModulePaths) {
    Write-Warning 'No PSModulePaths found in $env:PSModulePath. If you are doing isolated testing you can disregard this.'
    return
  }

  #We want to minimize reading the manifest files, so we will do a fast file-based search first and then do a more detailed inspection on high confidence candidate(s). Any module in any folder path that satisfies the spec will be sufficient, we don't care about finding the "latest" version, so we will return the first module that satisfies the spec. We will store potential candidates in this list, with their evaluated "guessed" version based on the folder name and the path. The first items added to the list should be the highest likelihood candidates in Path priority order, so no sorting should be necessary.

  foreach ($modulePath in $ModulePaths) {
    [List[[Tuple[Version, string]]]]$candidatePaths = @()
    if (-not [Directory]::Exists($modulePath)) {
      Write-Debug "${ModuleSpec}: Skipping PSModulePath $modulePath - Configured but does not exist."
      $modulePaths = $modulePaths | Where-Object { $_ -ne $modulePath }
      continue
    }

    #Linux/Mac support requires a case insensitive search on a user supplied variable.
    $moduleBaseDir = [Directory]::GetDirectories($modulePath, $moduleSpec.Name, [EnumerationOptions]@{MatchCasing = 'CaseInsensitive' })
    if ($moduleBaseDir.count -gt 1) { throw "$($moduleSpec.Name) folder is ambiguous, please delete one of these folders: $moduleBaseDir" }
    if (-not $moduleBaseDir) {
      Write-Debug "${ModuleSpec}: Skipping PSModulePath $modulePath - Does not have this module."
      continue
    }

    #We can attempt a fast-search for modules if the ModuleSpec is for a specific version
    $required = $ModuleSpec.Required
    if ($required) {

      #If there is a prerelease, we will fetch the folder where the prerelease might live, and verify the manifest later.
      [Version]$moduleVersion = Resolve-FolderVersion $required

      $moduleFolder = Join-Path $moduleBaseDir $moduleVersion
      $manifestPath = Join-Path $moduleFolder $manifestName

      if (Test-Path $ModuleFolder) {
        $candidatePaths.Add([Tuple]::Create([version]$moduleVersion, $manifestPath))
      }
    } else {
      #Check for versioned module folders next and sort by the folder versions to process them in descending order.
      [Directory]::GetDirectories($moduleBaseDir)
      | ForEach-Object {
        $folder = $PSItem
        $version = $null
        $isVersion = [Version]::TryParse((Split-Path -Leaf $PSItem), [ref]$version)
        if (-not $isVersion) {
          Write-Debug "Could not parse $folder in $moduleBaseDir as a valid version. This is either a bad version directory or this folder is a classic module."
          return
        }

        #Fast filter items that are above the upper bound, we dont need to read these manifests
        if ($ModuleSpec.Max -and $version -gt $ModuleSpec.Max.Version) {
          Write-Debug "${ModuleSpec}: Skipping $folder - above the upper bound"
          return
        }

        #We can fast filter items that are below the lower bound, we dont need to read these manifests
        if ($ModuleSpec.Min) {
          #HACK: Nuget does not correctly convert major.minor.build versions
          [version]$originalBaseVersion = ($modulespec.Min.OriginalVersion -split '-')[0]
          [Version]$minVersion = $originalBaseVersion.Revision -eq -1 ? $originalBaseVersion : $ModuleSpec.Min.Version
          if ($version -lt $minVersion) {
            Write-Debug "${ModuleSpec}: Skipping $folder - $version is below the lower bound of $minVersion"
            return
          }
        }

        $candidatePaths.Add([Tuple]::Create([Version]$version, $PSItem))
      }
    }

    #Check for a "classic" module if no versioned folders were found
    if ($candidatePaths.count -eq 0) {
      [string[]]$classicManifestPaths = [Directory]::GetFiles($moduleBaseDir, $manifestName, [EnumerationOptions]@{MatchCasing = 'CaseInsensitive' })
      if ($classicManifestPaths.count -gt 1) { throw "$moduleBaseDir manifest is ambiguous, please delete one of these: $classicManifestPath" }
      [string]$classicManifestPath = $classicManifestPaths[0]
      if ($classicManifestPath) {
        #NOTE: This does result in Import-PowerShellData getting called twice which isn't ideal for performance, but classic modules should be fairly rare and not worth optimizing.
        [version]$classicVersion = (Import-ModuleManifest $classicManifestPath).ModuleVersion
        Write-Debug "${ModuleSpec}: Found classic module $classicVersion at $moduleBaseDir"
        $candidatePaths.Add([Tuple[Version, String]]::new($classicVersion, $moduleBaseDir))
      }
    }

    if ($candidatePaths.count -eq 0) {
      Write-Debug "${ModuleSpec}: Skipping PSModulePath $modulePath - No installed versions matched the spec."
      continue
    }

    foreach ($candidateItem in $candidatePaths) {
      [version]$version = $candidateItem.Item1
      [string]$folder = $candidateItem.Item2

      #Make sure this isn't an incomplete installation
      if (Test-Path (Join-Path $folder '.incomplete')) {
        Write-Warning "${ModuleSpec}: Incomplete installation detected at $folder. Deleting and ignoring."
        Remove-Item $folder -Recurse -Force
        continue
      }

      #Read the module manifest to check for prerelease versions.
      $manifestName = "$($ModuleSpec.Name).psd1"
      $versionedManifestPath = [Directory]::GetFiles($folder, $manifestName, [EnumerationOptions]@{MatchCasing = 'CaseInsensitive' })

      if ($versionedManifestPath.count -gt 1) { throw "$folder manifest is ambiguous, this happens on Linux if you have two manifests with different case sensitivity. Please delete one of these: $versionedManifestPath" }

      if (-not $versionedManifestPath) {
        Write-Warning "${ModuleSpec}: Found a candidate versioned module folder $folder but no $manifestName manifest was found in the folder. This is an indication of a corrupt module and you should clean this folder up"
        continue
      }

      #Read the manifest so we can compare prerelease info. If this matches, we have a valid candidate and don't need to check anything further.
      $manifestCandidate = ConvertFrom-ModuleManifest $versionedManifestPath[0]
      if ($ModuleSpec.Guid -and $ModuleSpec.Guid -ne [Guid]::Empty -and $manifestCandidate.Guid -ne $ModuleSpec.Guid) {
        Write-Warning "${ModuleSpec}: A locally installed module $folder that matches the module spec but the manifest GUID $($manifestCandidate.Guid) does not match the expected GUID $($ModuleSpec.Guid) in the spec. Verify your specification is correct otherwise investigate this module for why the GUID does not match."
        continue
      }
      $candidateVersion = $manifestCandidate.ModuleVersion

      if ($ModuleSpec.SatisfiedBy($candidateVersion, $StrictSemVer)) {
        if ($Update -and ($ModuleSpec.Max -ne $candidateVersion)) {
          Write-Debug "${ModuleSpec}: Skipping $candidateVersion because -Update was specified and the version does not exactly meet the upper bound of the spec or no upper bound was specified at all, meaning there is a possible newer version remotely."
          #We can use this ref later to find out if our best remote version matches what is installed without having to read the manifest again
          if (-not $bestCandidate.Value[$moduleSpec] -or
            $manifestCandidate.ModuleVersion -gt $bestCandidate.Value[$moduleSpec].ModuleVersion
          ) {
            Write-Debug "${ModuleSpec}: ⬆️ New Best Candidate Version $($manifestCandidate.ModuleVersion)"
            $BestCandidate.Value[$moduleSpec] = $manifestCandidate
          }
          continue
        }

        #TODO: Collect InstalledButSatisfied Modules into an array so they can later be referenced in the lockfile and/or plan, right now the lockfile only includes modules that changed.
        return $manifestCandidate
      }
    }
  }
}


function ConvertTo-AuthenticationHeaderValue ([PSCredential]$Credential) {
  $basicCredential = [Convert]::ToBase64String(
    [Encoding]::UTF8.GetBytes(
			($Credential.UserName, $Credential.GetNetworkCredential().Password -join ':')
    )
  )
  return [Net.Http.Headers.AuthenticationHeaderValue]::New('Basic', $basicCredential)
}

#Get the hash of a string
function Get-StringHash ([string]$String, [string]$Algorithm = 'SHA256') {
	(Get-FileHash -InputStream ([MemoryStream]::new([Encoding]::UTF8.GetBytes($String))) -Algorithm $algorithm).Hash
}

#Imports a powershell data file or json file for the required spec configuration.
filter ConvertFrom-RequiredSpec {
  [CmdletBinding(DefaultParameterSetName = 'File')]
  [OutputType([ModuleFastSpec[]])]
  param(
    [Parameter(Mandatory, ParameterSetName = 'File')][string]$RequiredSpecPath,
    [Parameter(Mandatory, ParameterSetName = 'Object')]$RequiredSpec,
    [SpecFileType]$SpecFileType
  )
  $ErrorActionPreference = 'Stop'

  #If a spec path was specified, resolve it into RequiredSpec
  if ($RequiredSpecPath) {
    $specFromUri = Read-RequiredSpecFile $RequiredSpecPath
    $RequiredSpec = $specFromUri
  }

  $PassThruTypes = [string],
  [string[]],
  [ModuleFastSpec],
  [ModuleFastSpec[]],
  [ModuleSpecification[]],
  [ModuleSpecification]

  if ($RequiredSpec.GetType() -in $PassThruTypes) { return [ModuleFastSpec[]]$requiredSpec }

  if ($RequiredSpec -is [PSCustomObject] -and $RequiredSpec.psobject.baseobject -isnot [IDictionary]) {
    Write-Debug 'PSCustomObject-based Spec detected, converting to hashtable'
    $requireHT = @{}
    $RequiredSpec.psobject.Properties
  | ForEach-Object {
      $requireHT.Add($_.Name, $_.Value)
    }
    #Will be process by IDictionary case below
    $RequiredSpec = $requireHT
  }

  if ($RequiredSpec -is [IDictionary]) {

    if ($SpecFileType -eq 'AutoDetect') {
      $SpecFileType = Select-RequiredSpecFileType $RequiredSpec
    }
    if ($SpecFileType -eq 'AutoDetect') {throw 'There was an unexpected error processing the spec file type. This is a bug that should be reported.'}

    switch ($SpecFileType) {
      ([SpecFileType]::PSDepend) {
        Write-Debug 'Requires Parse: PSDepend Spec specified, evaluating...'
        return ConvertFrom-PSDepend $requiredSpec
      }
      ([SpecFileType]::PSResourceGet) {
        Write-Debug 'Requires Parse: PSResourceGet Spec specified, evaluating...'
        return ConvertFrom-PSResourceGet $requiredSpec
      }
    }

    foreach ($kv in $RequiredSpec.GetEnumerator()) {
      if ($kv.Value -is [IDictionary]) {
        throw [NotSupportedException]'ModuleFast SpecFile detected but the value is a hashtable. This is not supported. Try using the -SpecFileType parameter if you expected another format'
      }
      if ($kv.Value -isnot [string]) {
        throw [NotSupportedException]'Only strings and hashtables are supported on the right hand side of the = operator.'
      }
      if ($kv.Value -eq 'latest') {
        [ModuleFastSpec]"$($kv.Name)"
        continue
      }
      if ($kv.Value -as [NuGetVersion]) {
        [ModuleFastSpec]::new($kv.Name, $kv.Value)
        continue
      }
      if ($kv.Value -as [VersionRange]) {
        [ModuleFastSpec]::new($kv.Name, ($kv.Value -as [VersionRange]))
        continue
      }

      #All other potential options (<=, @, :, etc.) are a direct merge
      try {
        [ModuleFastSpec]"$($kv.Name)$($kv.Value)"
      } catch {
        throw [NotSupportedException]"Could not parse $($kv.Value) as a valid ModuleFastSpec. Check out the simplified syntax instructions for your options."
      }
    }
    return
  }

  if ($RequiredSpec -is [Object[]] -and ($true -notin $RequiredSpec.GetEnumerator().Foreach{ $PSItem -isnot [string] })) {
    Write-Debug 'RequiredData array detected and contains all string objects. Converting to string[]'
    $RequiredSpec = [string[]]$RequiredSpec
  }

  throw [InvalidDataException]'Could not evaluate the Required Specification to a known format.'
}

function Find-RequiredSpecFile ([string]$Path) {
  Write-Debug "Attempting to find Required Specfile(s) at $Path"

  $resolvedPath = Resolve-Path $Path

  $requireFiles = Get-Item $resolvedPath/*.requires.* -ErrorAction SilentlyContinue
  | Where-Object {
    $extension = [Path]::GetExtension($_.FullName)
    $extension -in '.psd1', '.ps1', '.psm1', '.json', '.jsonc'
  }

  if (-not $requireFiles) {
    throw [NotSupportedException]"Could not find any required spec files in $Path. Verify the path is correct or provide Module Specifications either via -Path or -Specification"
  }
  return $requireFiles
}

function Select-RequiredSpecFileType ([IDictionary]$requiredSpec) {
  Write-Debug 'SpecFile Parse: Attempting to auto-detect SpecFile type'
  foreach ($key in $requiredSpec.Keys) {
    if ($key -match '::|/') {
      Write-Debug 'SpecFile Parse: Auto-detected SpecFile type as PSDepend due to presence of :: or / in keys'
      return [SpecFileType]::PSDepend
    }
    if ($key -eq 'PSDependOptions') {
      Write-Debug 'SpecFile Parse: Auto-detected SpecFile type as PSDepend due to presence of PSDependOptions key'
      return [SpecFileType]::PSDepend
    }

    if ($requiredSpec[$key] -is [IDictionary]) {
      if ($requiredSpec[$key].ContainsKey('DependencyType')) {
        Write-Debug 'SpecFile Parse: Auto-detected SpecFile type as PSDepend due to presence of DependencyType key'
        return [SpecFileType]::PSDepend
      }
      if ($requiredSpec[$key].ContainsKey('Repository') -or $requiredSpec[$key].ContainsKey('Version')) {
        Write-Debug 'SpecFile Parse: Auto-detected SpecFile type as PSResourceGet/RequiredModules due to presence of Repository or Version key'
        return [SpecFileType]::PSResourceGet
      }
    }
  }
  Write-Debug 'SpecFile Parse: Auto-detected SpecFile type as ModuleFast due to lack of other indicators'
  return [SpecFileType]::ModuleFast
}

function Read-RequiredSpecFile ($RequiredSpecPath) {
  if ($uri.scheme -in 'http', 'https') {
    [string]$content = (Invoke-WebRequest -Uri $uri).Content
    if ($content.StartsWith('@{')) {
      #HACK: Cannot read PowerShell Data Files from a string, the interface is private, so we write to a temp file as a workaround.
      $tempFile = [io.path]::GetTempFileName()
      $content > $tempFile
      return Import-ModuleManifest -Path $tempFile
    } else {
      $json = ConvertFrom-Json $content -Depth 5
      return $json
    }
  }

  #Assume this is a local if a URL above didn't match
  $resolvedPath = Resolve-Path $RequiredSpecPath
  $extension = [Path]::GetExtension($resolvedPath)

  if ($extension -eq '.psd1') {
    $manifestData = Import-ModuleManifest -Path $resolvedPath
    if ($manifestData.ModuleVersion) {
      [ModuleSpecification[]]$requiredModules = $manifestData.RequiredModules
      Write-Debug 'Detected a Module Manifest, evaluating RequiredModules'
      if ($requiredModules.count -eq 0) {
        throw [InvalidDataException]'The manifest does not have a RequiredModules key so ModuleFast does not know what this module requires. See Get-Help about_module_manifests for more.'
      }
      return , $requiredModules
    } else {
      Write-Debug 'Did not detect a module manifest, passing through as-is'
      return $manifestData
    }
  }

  if ($extension -in '.ps1', '.psm1') {
    Write-Debug 'PowerShell Script/Module file detected, checking for #Requires'
    $ast = [Parser]::ParseFile($resolvedPath, [ref]$null, [ref]$null)
    [ModuleSpecification[]]$requiredModules = $ast.ScriptRequirements.RequiredModules

    if ($RequiredModules.count -eq 0) {
      throw [NotSupportedException]'The script does not have a #Requires -Module statement so ModuleFast does not know what this module requires. See Get-Help about_requires for more.'
    }
    return , $requiredModules
  }

  if ($extension -in '.json', '.jsonc') {
    $json = Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json -Depth 5
    if ($json -is [Object[]] -and $false -notin $json.getenumerator().foreach{ $_ -is [string] }) {
      Write-Debug 'Detected a JSON array of strings, converting to string[]'
      return , [string[]]$json
    }
    return $json
  }

  throw [NotSupportedException]'Only .ps1, psm1, .psd1, and .json files are supported to import to this command'
}

filter Resolve-FolderVersion([NuGetVersion]$version) {
  if ($version.IsLegacyVersion -or $version.OriginalVersion -match '\d+\.\d+\.\d+\.\d+') {
    return $version.version
  }
  [Version]::new($version.Major, $version.Minor, $version.Patch)
}

filter ConvertFrom-ModuleManifest {
  [CmdletBinding()]
  [OutputType([ModuleFastInfo])]
  param(
    [Parameter(Mandatory)][string]$ManifestPath
  )
  $ErrorActionPreference = 'Stop'

  $ManifestName = Split-Path -Path $ManifestPath -LeafBase
  $manifestData = Import-ModuleManifest -Path $ManifestPath

  [Version]$manifestVersionData = $null
  if (-not [Version]::TryParse($manifestData.ModuleVersion, [ref]$manifestVersionData)) {
    throw [InvalidDataException]"The manifest at $ManifestPath has an invalid ModuleVersion $($manifestData.ModuleVersion). This is probably an invalid or corrupt manifest"
  }

  [NuGetVersion]$manifestVersion = [NuGetVersion]::new(
    $manifestVersionData,
    $manifestData.PrivateData.PSData.Prerelease
  )

  $moduleFastInfo = [ModuleFastInfo]::new($ManifestName, $manifestVersion, $ManifestPath)
  if ($manifestVersion.Guid) {
    $moduleFastInfo.Guid = $manifestVersion.Guid
  }
  return $moduleFastInfo
}
#Fixes an issue where ShouldProcess will not respect ConfirmPreference if -Debug is specified


function Approve-Action {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", '', Scope='Function')]
  param(
    [ValidateNotNullOrEmpty()][string]$Target,
    [ValidateNotNullOrEmpty()][string]$Action,
    $ThisCmdlet = $PSCmdlet
  )
  $ShouldProcessMessage = 'Performing the operation "{0}" on target "{1}"' -f $Action, $Target
  if ($ENV:CI -or $CI) {
    Write-Verbose "$ShouldProcessMessage (Auto-Confirmed because `$ENV:CI is specified)"
    return $true
  }
  if ($ConfirmPreference -eq 'None') {
    Write-Verbose "$ShouldProcessMessage (Auto-Confirmed because `$ConfirmPreference is set to 'None')"
    return $true
  }

  return $ThisCmdlet.ShouldProcess($Target, $Action)
}

#Fetches the module path for the current user or all users.
#HACK: Uses a private API until https://github.com/PowerShell/PowerShell/issues/15552 is resolved
function Get-PSDefaultModulePath ([Switch]$AllUsers) {
    $scopeType = [Management.Automation.Configuration.ConfigScope]
    $pscType = $scopeType.
    Assembly.
    GetType('System.Management.Automation.Configuration.PowerShellConfig')

    $pscInstance = $pscType.
    GetField('Instance', [Reflection.BindingFlags]'Static,NonPublic').
    GetValue($null)

    $getModulePathMethod = $pscType.GetMethod('GetModulePath', [Reflection.BindingFlags]'Instance,NonPublic')

    if ($AllUsers) {
        $getModulePathMethod.Invoke($pscInstance, $scopeType::AllUsers) ?? [Management.Automation.ModuleIntrinsics]::GetPSModulePath('BuiltIn')
    } else {
        $getModulePathMethod.Invoke($pscInstance, $scopeType::CurrentUser) ?? [Management.Automation.ModuleIntrinsics]::GetPSModulePath('User')
    }
}

#endregion Helpers

### ISSUES
# FIXME: When doing directory match comparison for local modules, need to preserve original folder name. See: Reflection 4.8
#   To fix this we will just use the name out of the module.psd1 when installing
# FIXME: DBops dependency version issue

Set-Alias imf -Value Install-ModuleFast
Export-ModuleMember -Function Get-ModuleFastPlan, Install-ModuleFast, Clear-ModuleFastCache -Alias imf
