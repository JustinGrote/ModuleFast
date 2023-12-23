#requires -version 7.2 -Modules Microsoft.Powershell.SecretManagement
using namespace Microsoft.PowerShell.Commands
using namespace System.Management.Automation
using namespace System.Management.Automation.Language
using namespace NuGet.Versioning
using namespace System.Collections
using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.IO
using namespace System.IO.Compression
using namespace System.IO.Pipelines
using namespace System.Net
using namespace System.Net.Http
using namespace System.Reflection
using namespace System.Text
using namespace System.Threading
using namespace System.Threading.Tasks

#Because we are changing state, we want to be safe
#TODO: Implement logic to only fail on module installs, such that one module failure doesn't prevent others from installing.
#Probably need to take into account inconsistent state, such as if a dependent module fails then the depending modules should be removed.
$ErrorActionPreference = 'Stop'

#Default Source is PWSH Gallery
$SCRIPT:DefaultSource = 'https://pwsh.gallery/index.json'

#region Public
<#
.SYNOPSIS
High performance, declarative Powershell Module Installer
.DESCRIPTION
ModuleFast is a high performance, declarative PowerShell module installer. It is designed with no external dependencies and can be bootstrapped in a single line of code. It is ideal for Continuous Integration/Deployment and serverless scenarios where you want to install modules quickly and without any user interaction. It is inspired by pnpm and other high performance declarative package managers.

ModuleFast accepts a variety of familiar PowerShell syntaxes and objects for module specification as well as a custom shorthand syntax allowing complex version requirements to be defined in a single string.

ModuleFast can also install the required modules specified in the #Requires line of a script, or in the RequiredModules section of a module manifest, by simplying providing the path to that file in the -Path parameter (which also accepts remote UNC, http, and https URLs).

.EXAMPLE
Install-ModuleFast 'Az'
.EXAMPLE
$plan = Get-ModuleFastPlan 'Az','VMWare.PowerCLI'
$plan | Install-ModuleFast
.EXAMPLE
$plan = Install-ModuleFast 'Az','VMWare.PowerCLI' -WhatIf
$plan | Install-ModuleFast
#>
function Install-ModuleFast {
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
    #Setting this will check for newer modules if your installed modules are not already at the upper bound of the required version range.
    [Switch]$Update,
    #Consider prerelease packages in the evaluation. Note that if a non-prerelease package has a prerelease dependency, that dependency will be included regardless of this setting.
    [Switch]$Prerelease,
    #Using the CI switch will write a lockfile to the current folder. If this file is present and -CI is specified in the future, ModuleFast will only install the versions specified in the lockfile, which is useful for reproducing CI builds even if newer versions of software come out.
    [Switch]$CI,
    #The path to the lockfile. By default it is requires.lock.json in the current folder. This is ignored if CI is not present. It is generally not recommended to change this setting.
    [string]$CILockFilePath = $(Join-Path $PWD 'requires.lock.json'),
    [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ModuleFastInfo')][ModuleFastInfo]$ModuleFastInfo,
    #This will output the resulting modules that were installed.
    [Switch]$PassThru
  )
  begin {
    # Setup the Destination repository
    $defaultRepoPath = $(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'powershell/Modules')

    if (-not $Destination) {
      $Destination = $defaultRepoPath
    } elseif ($IsWindows -and $Destination -eq 'CurrentUser') {
      $windowsDefaultDocumentsPath = Join-Path [environment]::GetFolderPath('MyDocuments') 'PowerShell/Modules'
      $Destination = $windowsDefaultDocumentsPath
    }

    # Autocreate the default as a convenience, otherwise require the path to be present to avoid mistakes
    if ($Destination -eq $defaultRepoPath -and -not (Test-Path $Destination)) {
      if ($PSCmdlet.ShouldProcess('Create Destination Folder', $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
      }
    }

    $Destination = Resolve-Path $Destination

    if (-not $NoPSModulePathUpdate) {
      if ($defaultRepoPath -ne $Destination -and $Destination -notin $PSModulePaths) {
        Write-Warning 'Parameter -Destination is set to a custom path not in your current PSModulePath. We will add it to your PSModulePath for this session. You can suppress this behavior with the -NoPSModulePathUpdate switch.'
        $NoProfileUpdate = $true
      }

      $addToPathParams = @{
        Destination     = $Destination
        NoProfileUpdate = $NoProfileUpdate
      }
      if ($PSBoundParameters.ContainsKey('Confirm')) {
        $addToPathParams.Confirm = $PSBoundParameters.Confirm
      }
      Add-DestinationToPSModulePath @addtoPathParams
    }

    $currentWhatIfPreference = $WhatIfPreference
    #We do some stuff here that doesn't affect the system but triggers whatif, so we disable it
    $WhatIfPreference = $false

    #We want to maintain a single HttpClient for the life of the module. This isn't as big of a deal as it used to be but
    #it is still a best practice.
    if (-not $SCRIPT:__ModuleFastHttpClient -or $Source -ne $SCRIPT:__ModuleFastHttpClient.BaseAddress) {
      $SCRIPT:__ModuleFastHttpClient = New-ModuleFastClient -Credential $Credential
      if (-not $SCRIPT:__ModuleFastHttpClient) {
        throw 'Failed to create ModuleFast HTTPClient. This is a bug'
      }
    }
    $httpClient = $SCRIPT:__ModuleFastHttpClient

    $cancelSource = [CancellationTokenSource]::new()
  }

  process {
    #We initialize and type the container list here because there is a bug where the ParameterSet is not correct in the begin block if the pipeline is used. Null conditional keeps it from being reinitialized
    [List[ModuleFastSpec]]$ModulesToInstall = @()
    switch ($PSCmdlet.ParameterSetName) {
      'Specification' {
        [List[ModuleFastSpec]]$ModulesToInstall ??= @()
        foreach ($ModuleToInstall in $Specification) {
          $ModulesToInstall.Add($ModuleToInstall)
        }
        break
      }
      'ModuleFastInfo' {
        [List[ModuleFastInfo]]$ModulesToInstall ??= @()
        foreach ($ModuleToInstall in $ModuleFastInfo) {
          $ModulesToInstall.Add($ModuleToInstall)
        }
        break

      }
      'Path' {
        $ModulesToInstall = ConvertFrom-RequiredSpec -RequiredSpecPath $Path
      }
    }
  }

  end {

    if ($ModulesToInstall.Count -eq 0 -and $PSCmdlet.ParameterSetName -eq 'Specification') {
      Write-Verbose 'No modules specified to install. Beginning SpecFile detection...'
      $modulesToInstall = if ($CI -and (Test-Path $CILockFilePath)) {
        Write-Debug "Found lockfile at $CILockFilePath. Using for specification evaluation and ignoring all others."
        ConvertFrom-RequiredSpec -RequiredSpecPath $CILockFilePath
      } else {
        $specFiles = Find-RequiredSpecFile $PWD -CILockFileHint $CILockFilePath
        foreach ($specfile in $specFiles) {
          ConvertFrom-RequiredSpec -RequiredSpecPath $Path
        }
      }
    }

    if (-not $ModulesToInstall) {
      throw [InvalidDataException]'No modules specifications found to evaluate.'
    }

    #If we do not have an explicit implementation plan, fetch it
    #This is done so that Get-ModuleFastPlan | Install-ModuleFastPlan and Install-ModuleFastPlan have the same flow.
    [ModuleFastInfo[]]$plan = if ($PSCmdlet.ParameterSetName -eq 'ModuleFastInfo') {
      $ModulesToInstall.ToArray()
    } else {
      Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status 'Plan' -PercentComplete 1
      Get-ModuleFastPlan -Specification $ModulesToInstall -HttpClient $httpClient -Source $Source -Update:$Update -PreRelease:$Prerelease.IsPresent
    }

    $WhatIfPreference = $currentWhatIfPreference

    if ($plan.Count -eq 0) {
      $planAlreadySatisfiedMessage = "`u{2705} $($ModulesToInstall.count) Module Specifications have all been satisfied by installed modules. If you would like to check for newer versions remotely, specify -Update"
      if ($WhatIfPreference) {
        Write-Host -fore DarkGreen $planAlreadySatisfiedMessage
      } else {
        Write-Verbose $planAlreadySatisfiedMessage
      }
      return
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, "Install $($plan.Count) Modules")) {
      # Write-Host -fore DarkGreen "`u{1F680} ModuleFast Install Plan BEGIN"
      #TODO: Separate planned installs and dependencies
      $plan
      # Write-Host -fore DarkGreen "`u{1F680} ModuleFast Install Plan END"
      return
    }

    Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status "Installing: $($plan.count) Modules" -PercentComplete 50

    $installHelperParams = @{
      ModuleToInstall   = $plan
      Destination       = $Destination
      CancellationToken = $cancelSource.Token
      HttpClient        = $httpClient
      Update            = $Update
    }
    Install-ModuleFastHelper @installHelperParams
    Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Completed
    Write-Verbose "`u{2705} All required modules installed! Exiting."
    if ($CI) {
      #FIXME: If a package was already installed, it doesn't show up in this lockfile.
      Write-Verbose "Writing lockfile to $CILockFilePath"
      [Dictionary[string, string]]$lockFile = @{}
      $plan
      | ForEach-Object {
        $lockFile.Add($PSItem.Name, $PSItem.ModuleVersion)
      }

      $lockFile
      | ConvertTo-Json -Depth 2
      | Out-File -FilePath $CILockFilePath -Encoding UTF8
    }
  }
  CLEAN {
    $cancelSource.Dispose()
  }
}

function New-ModuleFastClient {
  param(
    [PSCredential]$Credential
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
  $httpClient.Timeout = [TimeSpan]::FromSeconds(30)

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
  [CmdletBinding()]
  [OutputType([ModuleFastInfo])]
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
    [HttpClient]$HttpClient = $(New-ModuleFastClient -Credential $Credential),
    [int]$ParentProgress,
    [CancellationToken]$CancellationToken
  )

  BEGIN {
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
    foreach ($spec in $Specification) {
      if (-not $ModulesToResolve.Add($spec)) {
        Write-Warning "$spec was specified twice, skipping duplicate"
      }
    }
  }
  END {
    # A deduplicated list of modules to install
    [HashSet[ModuleFastInfo]]$modulesToInstall = @{}

    # We use this as a fast lookup table for the context of the request
    [Dictionary[Task[String], ModuleFastSpec]]$taskSpecMap = @{}

    #We use this to track the tasks that are currently running
    #We dont need this to be ConcurrentList because we only manipulate it in the "main" runspace.
    [List[Task[String]]]$currentTasks = @()


    #This try finally is so that we can interrupt all http call tasks if Ctrl-C is pressed
    foreach ($moduleSpec in $ModulesToResolve) {
      #This is used to track the highest candidate if -Update was specified to force a remote lookup. If the candidate is still the most valid after remote lookup we can skip it without hitting disk to read the manifest again.
      [ModuleFastInfo]$bestLocalCandidate = $null

      Write-Verbose "${moduleSpec}: Evaluating Module Specification"
      [ModuleFastInfo]$localMatch = Find-LocalModule $moduleSpec -Update:$Update -BestCandidate:([ref]$bestLocalCandidate)
      if ($localMatch) {
        Write-Debug "${localMatch}: 🎯 FOUND satisfing version $($localMatch.ModuleVersion) at $($localMatch.Location). Skipping remote search."
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

      [Task[string]]$completedTask = $currentTasks[$thisTaskIndex]
      [ModuleFastSpec]$currentModuleSpec = $taskSpecMap[$completedTask]

      Write-Debug "$currentModuleSpec`: Processing Response"
      # We use GetAwaiter so we get proper error messages back, as things such as network errors might occur here.
      try {
        $response = $completedTask.GetAwaiter().GetResult()
        | ConvertFrom-Json
        Write-Debug "$currentModuleSpec`: Received Response with $($response.Count) pages"
      } catch {
        $taskException = $PSItem.Exception.InnerException
        #TODO: Rewrite this as a handle filter
        if ($taskException -isnot [HttpRequestException]) { throw }
        [HttpRequestException]$err = $taskException
        if ($err.StatusCode -eq [HttpStatusCode]::NotFound) {
          throw [InvalidOperationException]"$currentModuleSpec`: module was not found in the $Source repository. Check the spelling and try again."
        }

        #All other cases
        $PSItem.ErrorDetails = "$currentModuleSpec`: Failed to fetch module $currentModuleSpec from $Source. Error: $PSItem"
        throw $PSItem
      }

      if (-not $response.count) {
        throw [InvalidDataException]"$currentModuleSpec`: invalid result received from $Source. This is probably a bug. Content: $response"
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
          throw [NotImplementedException]"$currentModuleSpec`: Script installations are currently not supported."
        }

        [SortedSet[NuGetVersion]]$inlinedVersions = $entries.version

        foreach ($candidate in $inlinedVersions.Reverse()) {
          #Skip Prereleases unless explicitly requested
          if (($candidate.IsPrerelease -or $candidate.HasMetadata) -and -not ($currentModuleSpec.PreRelease -or $Prerelease)) {
            Write-Debug "${moduleSpec}: skipping candidate $candidate because it is a prerelease and prerelease was not specified either with the -Prerelease parameter, by specifying a prerelease version in the spec, or adding a ! on the module name spec to indicate prerelease is acceptable."
            continue
          }

          if ($currentModuleSpec.SatisfiedBy($candidate)) {
            #TODO: If the found version still matches an installed version, we should skip it
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
        Write-Debug "$currentModuleSpec`: not found in inlined index. Determining appropriate page(s) to query"

        #If not inlined, we need to find what page(s) might have the candidate info we are looking for, starting with the highest numbered page first

        $pages = $response.items
        | Where-Object { -not $PSItem.items } #Get non-inlined pages
        | Where-Object {
          [VersionRange]$pageRange = [VersionRange]::new($PSItem.Lower, $true, $PSItem.Upper, $true, $null, $null)
          return $currentModuleSpec.Overlap($pageRange)
        }
        | Sort-Object -Descending { [NuGetVersion]$PSItem.Upper }

        if (-not $pages) {
          throw [InvalidOperationException]"$currentModuleSpec`: a matching module was not found in the $Source repository that satisfies the requested version constraints. You may need to specify -PreRelease or adjust your version constraints."
        }

        Write-Debug "$currentModuleSpec`: Found $(@($pages).Count) additional pages that might match the query: $($pages.'@id' -join ',')"

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

              if ($currentModuleSpec.SatisfiedBy($candidate)) {
                Write-Debug "$currentModuleSpec`: Found satisfying version $candidate in the additional pages."
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
        throw [InvalidOperationException]"$currentModuleSpec`: a matching module was not found in the $Source repository that satisfies the version constraints. You may need to specify -PreRelease or adjust your version constraints."
      }
      if (-not $selectedEntry.PackageContent) { throw "No package location found for $($selectedEntry.PackageContent). This should never happen and is a bug" }

      [ModuleFastInfo]$selectedModule = [ModuleFastInfo]::new(
        $selectedEntry.id,
        $selectedEntry.version,
        $selectedEntry.PackageContent
      )

      #If -Update was specified, we need to re-check that none of the selected modules are already installed.
      #TODO: Persist state of the local modules found to this point so we don't have to recheck.
      if ($Update -and $bestLocalCandidate -and $bestLocalCandidate.ModuleVersion -eq $selectedModule.ModuleVersion) {
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

      Write-Verbose "$selectedModule`: Added to install plan"

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
        Write-Debug "$currentModuleSpec`: has $($dependencies.count) additional dependencies: $($dependencies -join ', ')"

        # TODO: Where loop filter maybe
        [ModuleFastSpec[]]$dependenciesToResolve = $dependencies | Where-Object {
          $dependency = $PSItem
          # TODO: This dependency resolution logic should be a separate function
          # Maybe ModulesToInstall should be nested/grouped by Module Name then version to speed this up, as it currently
          # enumerates every time which shouldn't be a big deal for small dependency trees but might be a
          # meaninful performance difference on a whole-system upgrade.
          [HashSet[string]]$moduleNames = $modulesToInstall.Name
          if ($dependency.Name -notin $ModuleNames) {
            Write-Debug "No modules with name $($dependency.Name) currently exist in the install plan. Resolving dependency..."
            return $true
          }

          $modulesToInstall
        | Where-Object Name -EQ $dependency.Name
        | Sort-Object ModuleVersion -Descending
        | ForEach-Object {
            if ($dependency.SatisfiedBy($PSItem.ModuleVersion)) {
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
          [ModuleFastInfo]$localMatch = Find-LocalModule $dependencySpec -Update:$Update
          if ($localMatch) {
            Write-Debug "FOUND local module $($localMatch.Name) $($localMatch.ModuleVersion) at $($localMatch.Location.AbsolutePath) that satisfies $moduleSpec. Skipping..."
            #TODO: Capture this somewhere that we can use it to report in the deploy plan
            continue
          } else {
            Write-Debug "No local modules that satisfies dependency $dependencySpec. Checking Remote..."
          }
          # TODO: Deduplicate in-flight queries (az.accounts is a good example)
          # Write-Debug "$moduleSpec`: Checking if $dependencySpec already has an in-flight request that satisfies the requirement"

          Write-Debug "$currentModuleSpec`: Fetching dependency $dependencySpec"
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
  }
  CLEAN {
    #Cancel any outstanding tasks if unexpected error occurs
    $cancelTokenSource.Dispose()
  }
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
    [switch]$Update
  )
  BEGIN {
    #We use this token to cancel the HTTP requests if the user hits ctrl-C without having to dispose of the HttpClient.
    #We get a child so that a cancellation here does not affect any upstream commands
    $cancelTokenSource = $CancellationToken ? [CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken) : [CancellationTokenSource]::new()
    $CancellationToken = $cancelTokenSource.Token
  }
  END {
    $ErrorActionPreference = 'Stop'

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
          throw "$module`: Existing module folder found at $installPath but the manifest could not be found. This is likely a corrupted or missing module and should be fixed manually."
        }

        #TODO: Dedupe all import-powershelldatafile operations to a function ideally
        $existingModuleMetadata = Import-PowerShellDataFile $existingManifestPath
        $existingVersion = [NugetVersion]::new(
          $existingModuleMetadata.ModuleVersion,
          $existingModuleMetadata.privatedata.psdata.prerelease
        )

        #Do a prerelease evaluation
        if ($module.ModuleVersion -eq $existingVersion) {
          if ($Update) {
            Write-Verbose "${module}: Existing module found at $installPath and its version $existingVersion is the same as the requested version. -Update was specified so we are assuming that the discovered online version is the same as the local version and skipping this module installation."
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
        throw "$module`: No Download Link found. This is a bug"
      }

      $streamTask = $httpClient.GetStreamAsync($module.Location, $CancellationToken)
      $context = @{
        Module      = $module
        InstallPath = $installPath
      }
      $taskMap.Add($streamTask, $context)
      $streamTask
    }

    #We are going to extract these straight out of memory, so we don't need to write the nupkg to disk
    Write-Verbose "$($context.Module): Extracting to $($context.installPath)"
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
      $installJob = Start-ThreadJob -ThrottleLimit 8 {
        param(
          [ValidateNotNullOrEmpty()]$stream = $USING:stream,
          [ValidateNotNullOrEmpty()]$context = $USING:context
        )
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

        $zip = [IO.Compression.ZipArchive]::new($stream, 'Read')
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $installPath)
        #FIXME: Output inside a threadjob is not surfaced to the user.
        Write-Debug "Cleanup Nuget Files in $installPath"
        if (-not $installPath) { throw 'ModuleDestination was not set. This is a bug, report it' }
        Get-ChildItem -Path $installPath | Where-Object {
          $_.Name -in '_rels', 'package', '[Content_Types].xml' -or
          $_.Name.EndsWith('.nuspec')
        } | Remove-Item -Force -Recurse
        ($zip).Dispose()
        ($stream).Dispose()
        Remove-Item $installIndicatorPath -Force
        return $context
      }
      $installJob
    }

    $installed = 0
    while ($installJobs.count -gt 0) {
      $ErrorActionPreference = 'Stop'
      $completedJob = $installJobs | Wait-Job -Any
      $completedJobContext = $completedJob | Receive-Job -Wait -AutoRemoveJob
      if (-not $installJobs.Remove($completedJob)) { throw 'Could not remove completed job from list. This is a bug, report it' }
      $installed++
      Write-Verbose "$($completedJobContext.Module)`: Installed to $($completedJobContext.InstallPath)"
      Write-Progress -Id 1 -Activity 'Install-ModuleFast' -Status "Install: $installed/$($ModuleToInstall.count) Modules" -PercentComplete ((($installed / $ModuleToInstall.count) * 50) + 50)
    }
  }
}

#endregion Private

#region Classes

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
class ModuleFastInfo: IComparable {
  [string]$Name
  #Sometimes the module version is not the same as the folder version, such as in the case of prerelease versions
  [NuGetVersion]$ModuleVersion
  #Path to the module, either local or remote
  [uri]$Location
  #TODO: This should be a getter
  [boolean]$IsLocal

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
  DefaultDisplayPropertySet = 'Name', 'ModuleVersion'
  DefaultKeyPropertySet     = 'Name', 'ModuleVersion'
  SerializationMethod       = 'SpecificProperties'
  PropertySerializationSet  = 'Name', 'ModuleVersion', 'Location'
  SerializationDepth        = 0
}
[ModuleFastInfo] | Add-Getters
Update-TypeData -TypeName ModuleFastInfo @ModuleFastInfoTypeData -Force
Update-TypeData -TypeName Nuget.Versioning.NugetVersion -SerializationMethod String -Force

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
    # TODO: Fix this check logic
    # if ($this.Guid -ne [Guid]::Empty -and -not $this.Required) {
    #   throw 'Cannot specify Guid unless min and max are the same. If you see this, it is probably a bug'
    # }
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
    return $this.SatisfiedBy([NuGetVersion]::new($Version))
  }

  [bool] SatisfiedBy([NugetVersion]$Version) {
    return $this._VersionRange.Satisfies($Version)
  }

  [bool] Overlap([ModuleFastSpec]$other) {
    return $this.Overlap($other._VersionRange)
  }

  [bool] Overlap([VersionRange]$other) {
    [List[VersionRange]]$ranges = @($this._VersionRange, $other)
    $subset = [versionrange]::CommonSubset($ranges)
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
    if ($this._VersionRange.MaxVersion -eq $this._VersionRange.MinVersion) {
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


#The supported hashtable types
enum HashtableType {
  ModuleSpecification
  PSDepend
  RequiredModule
  NugetRange
}

#endRegion Classes

#region Helpers

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
    #TODO: Only select supported versions
    #TODO: Cache this index more centrally to be used for other services
    Write-Debug ('{0}fetch registration index from {1}' -f ($ModuleId ? "$ModuleId`: " : ''), $Endpoint)
    if (-not $SCRIPT:__registrationIndex) {
      $SCRIPT:__registrationIndex = $HttpClient.GetStringAsync($Endpoint, $CancellationToken).GetAwaiter().GetResult()
    }

    $registrationBase = $SCRIPT:__registrationIndex
    | ConvertFrom-Json
    | Select-Object -ExpandProperty resources
    | Where-Object {
      $_.'@type' -match 'RegistrationsBaseUrl'
    }
    | Sort-Object -Property '@type' -Descending
    | Select-Object -ExpandProperty '@id' -First 1

    $uri = "$registrationBase/$($ModuleId.ToLower())/$Path"
  }

  #TODO: System.Text.JSON serialize this with fancy generic methods in 7.3?
  Write-Debug ('{0}fetch info from {1}' -f ($ModuleId ? "$ModuleId`: " : ''), $uri)

  return $HttpClient.GetStringAsync($uri, $CancellationToken)
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
    if (-not $PSCmdlet.ShouldProcess($myProfile, "Allow ModuleFast to work by creating a profile at $myProfile.")) { return }
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
    if (-not $PSCmdlet.ShouldProcess($myProfile, "Allow ModuleFast to work by adding $Destination to your PSModulePath on startup by appending to your CurrentUserAllHosts profile. If you do not want this, add -NoProfileUpdate to Install-ModuleFast or add the specified destination to your powershell.config.json or to your PSModulePath another way.")) { return }
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
    [string[]]$ModulePath = $($env:PSModulePath -split [Path]::PathSeparator),
    [Switch]$Update,
    [ref]$BestCandidate
  )
  $ErrorActionPreference = 'Stop'

  $modulePaths = $env:PSModulePath.Split([Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)
  if (-not $modulePaths) {
    Write-Warning 'No PSModulePaths found in $env:PSModulePath. If you are doing isolated testing you can disregard this.'
    return
  }

  #We want to minimize reading the manifest files, so we will do a fast file-based search first and then do a more detailed inspection on high confidence candidate(s). Any module in any folder path that satisfies the spec will be sufficient, we don't care about finding the "latest" version, so we will return the first module that satisfies the spec.

  #We will store potential candidates in this list, with their evaluated "guessed" version based on the folder name and the path. The first items added to the list should be the highest likelihood candidates in Path priority order, so no sorting should be necessary.


  foreach ($modulePath in $modulePaths) {
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
        $candidatePaths.Add([Tuple]::Create($moduleVersion, $manifestPath))
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
          #HACK: Nuget does not correctly convert major.minor.build versions.
          [version]$originalBaseVersion = ($modulespec.Min.OriginalVersion -split '-')[0]
          [Version]$minVersion = $originalBaseVersion.Revision -eq -1 ? $originalBaseVersion : $ModuleSpec.Min.Version
          if ($minVersion -lt $ModuleSpec.Min.OriginalVersion) {
            Write-Debug "${ModuleSpec}: Skipping $folder - below the lower bound"
            return
          }
        }

        $candidatePaths.Add([Tuple]::Create($version, $PSItem))
      }
    }

    #Check for a "classic" module if no versioned folders were found
    if ($candidatePaths.count -eq 0) {
      [string[]]$classicManifestPaths = [Directory]::GetFiles($moduleBaseDir, $manifestName, [EnumerationOptions]@{MatchCasing = 'CaseInsensitive' })
      if ($classicManifestPaths.count -gt 1) { throw "$moduleBaseDir manifest is ambiguous, please delete one of these: $classicManifestPath" }
      [string]$classicManifestPath = $classicManifestPaths[0]
      if ($classicManifestPath) {
        #NOTE: This does result in Import-PowerShellData getting called twice which isn't ideal for performance, but classic modules should be fairly rare and not worth optimizing.
        [version]$classicVersion = (Import-PowerShellDataFile $classicManifestPath).ModuleVersion
        Write-Debug "${ModuleSpec}: Found classic module $classicVersion at $moduleBaseDir"
        $candidatePaths.Add([Tuple]::Create($classicVersion, $moduleBaseDir))
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
      $candidateVersion = $manifestCandidate.ModuleVersion

      if ($ModuleSpec.SatisfiedBy($candidateVersion)) {
        if ($Update -and ($ModuleSpec.Max -ne $candidateVersion)) {
          Write-Debug "${ModuleSpec}: Skipping $candidateVersion because -Update was specified and the version does not exactly meet the upper bound of the spec or no upper bound was specified at all, meaning there is a possible newer version remotely."
          #We can use this ref later to find out if our best remote version matches what is installed without having to read the manifest again
          if ($BestCandidate -and $manifestCandidate.ModuleVersion -gt $bestCandidate.Value.ModuleVersion) {
            Write-Debug "${ModuleSpec}: New Best Candidate Version $($manifestCandidate.ModuleVersion)"
            $BestCandidate.Value = $manifestCandidate
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
    [Parameter(Mandatory, ParameterSetName = 'Object')]$RequiredSpec
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
    foreach ($kv in $RequiredSpec.GetEnumerator()) {
      if ($kv.Value -is [IDictionary]) {
        throw [NotImplementedException]'TODO: PSResourceGet/PSDepend full syntax'
      }
      if ($kv.Value -isnot [string]) {
        throw [NotSupportedException]'Only strings and hashtables are supported on the right hand side of the = operator.'
      }
      if ($kv.Value -eq 'latest') {
        [ModuleFastSpec]"$($kv.Name)"
        continue
      }
      if ($kv.Value -as [NuGetVersion]) {
        [ModuleFastSpec]"$($kv.Name)=$($kv.Value)"
        continue
      }

      #All other potential options (<=, @, :, etc.) are a direct merge
      [ModuleFastSpec]"$($kv.Name)$($kv.Value)"
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
  Write-Debug "Attempting to find a Required Spec file at $Path"

  $resolvedPath = Resolve-Path $Path

  $requireFiles = Get-Item $resolvedPath/*.requires.* -ErrorAction SilentlyContinue
  | Where-Object {
    $extension = [Path]::GetExtension($_.FullName)
    $extension -in '.psd1', '.ps1', '.psm1', '.json', '.jsonc'
  }

  if (-not $requireFiles) {
    throw [NotSupportedException]"Could not find any required spec files in $Path. Verify the path is correct or specify Module Specifications either via -Path or -Specification"
  }
}

function Read-RequiredSpecFile ($RequiredSpecPath) {
  if ($uri.scheme -in 'http', 'https') {
    [string]$content = (Invoke-WebRequest -Uri $uri).Content
    if ($content.StartsWith('@{')) {
      #HACK: Cannot read PowerShell Data Files from a string, the interface is private, so we write to a temp file as a workaround.
      $tempFile = [io.path]::GetTempFileName()
      $content > $tempFile
      return Import-PowerShellDataFile -Path $tempFile
    } else {
      $json = ConvertFrom-Json $content -Depth 5
      return $json
    }
  }

  #Assume this is a local if a URL above didn't match
  $resolvedPath = Resolve-Path $RequiredSpecPath
  $extension = [Path]::GetExtension($resolvedPath)

  if ($extension -eq '.psd1') {
    $manifestData = Import-PowerShellDataFile -Path $resolvedPath
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
  if ($version.IsLegacyVersion) {
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
  $manifestData = Import-PowerShellDataFile -Path $ManifestPath -ErrorAction stop

  [Version]$manifestVersionData = $null
  if (-not [Version]::TryParse($manifestData.ModuleVersion, [ref]$manifestVersionData)) {
    throw [InvalidDataException]"The manifest at $ManifestPath has an invalid ModuleVersion $($manifestData.ModuleVersion). This is probably an invalid or corrupt manifest"
  }

  [NuGetVersion]$manifestVersion = [NuGetVersion]::new(
    $manifestVersionData,
    $manifestData.PrivateData.PSData.Prerelease
  )

  return [ModuleFastInfo]::new($ManifestName, $manifestVersion, $ManifestPath)
}

#endregion Helpers

### ISSUES
# FIXME: When doing directory match comparison for local modules, need to preserve original folder name. See: Reflection 4.8
#   To fix this we will just use the name out of the module.psd1 when installing
# FIXME: DBops dependency version issue

Set-Alias imf -Value Install-ModuleFast
Export-ModuleMember -Function Get-ModuleFastPlan, Install-ModuleFast -Alias imf
