#requires -version 7
using namespace System.Text
using namespace System.IO
using namespace System.Net
using namespace System.Net.Http
using namespace System.Threading
using namespace System.Threading.Tasks
using namespace System.Collections.Generic
using namespace System.Collections.Concurrent
using namespace System.Collections.Specialized
using namespace System.Management.Automation
using namespace Microsoft.PowerShell.Commands

<#
.SYNOPSIS
High Performance Powershell Module Installation
.DESCRIPTION
This is a proof of concept for using the Powershell Gallery OData API and HTTPClient to parallel install packages
It is also a demonstration of using async tasks in powershell appropriately. Who says powershell can't be fast?
This drastically reduces the bandwidth/load against Powershell Gallery by only requesting the required data
.NOTES
THIS IS NOT FOR PRODUCTION, it should be considered "Fragile" and has very little error handling and type safety
It also doesn't generate the PowershellGet XML files currently, so PowershellGet will see them as "External" modules
#>

# if (-not (Get-Command 'nuget.exe')) {throw "This module requires nuget.exe to be in your path. Please install it."}


function Get-ModuleFastPlan {
    param(
        #A list of modules to install, specified either as strings or as hashtables with nuget version style (e.g. @{Name='test';Version='1.0'})
        [Parameter(Mandatory, ValueFromPipeline)][Object]$Name,
        #The repository to scan for modules. TODO: Multi-repo support
        [string]$Source = 'https://preview.pwsh.gallery/index.json',
        #Whether to include prerelease modules in the request
        [Switch]$PreRelease,
        #By default we use in-place modules if they satisfy the version requirements. This switch will force a search for all latest modules
        [Switch]$Update
    )

    BEGIN {
        $ErrorActionPreference = 'Stop'
        [HashSet[ComparableModuleSpecification]]$modulesToResolve = @()

        #We use this token to cancel the HTTP requests if the user hits ctrl-C without having to dispose of the HttpClient
        $cancelToken = [CancellationTokenSource]::new()

        if (-not $httpclient) {
            #SocketsHttpHandler is the modern .NET 5+ default handler for HttpClient.
            #We want more concurrent connections to improve our performance and fairly aggressive timeouts
            #The max connections are only in case we end up using HTTP/1.1 instead of HTTP/2 for whatever reason.
            $httpHandler = [SocketsHttpHandler]@{
                MaxConnectionsPerServer = 100
                # ConnectTimeout          = 1000
            }

            #Only need one httpclient for all operations, hence why we set it at Script (Module) scope
            #This is not as big of a deal as it used to be.
            $SCRIPT:httpClient = [HttpClient]::new($httpHandler)
            $httpClient.BaseAddress = $Source

            #This user agent is important, it indicates to pwsh.gallery that we want dependency-only metadata
            #TODO: Do this with a custom header instead
            $userHeaderAdded = $httpClient.DefaultRequestHeaders.UserAgent.TryParseAdd('ModuleFast (https://gist.github.com/JustinGrote/ecdf96b4179da43fb017dccbd1cc56f6)')
            if (-not $userHeaderAdded) {
                throw 'Failed to add User-Agent header to HttpClient. This is a bug'
            }
            #TODO: Add switch to force HTTP/2. Most of the time it should work fine tho
            # $httpClient.DefaultRequestVersion = '2.0'
            #I tried to drop support for HTTP/1.1 but proxies and cloudflare testing still require it

            #This will multiplex all queries over a single connection, minimizing TLS setup overhead
            #Should also support HTTP/3 on newest PS versions
            $httpClient.DefaultVersionPolicy = [HttpVersionPolicy]::RequestVersionOrHigher
            #This should enable HTTP/3 on Win11 22H2+ (or linux with http3 library) and PS 7.2+
            [void][AppContext]::SetSwitch('System.Net.SocketsHttpHandler.Http3Support', $true)
        }
        # Write-Progress -Id 1 -Activity 'Get-ModuleFast' -CurrentOperation 'Fetching module information from Powershell Gallery'
    }
    PROCESS {
        foreach ($spec in $Name) {
            if (-not $ModulesToResolve.Add($spec)) {
                Write-Warning "$spec was specified twice, skipping duplicate"
            }
        }
    }
    END {
        [HashSet[ComparableModuleSpecification]]$modulesToInstall = @{}

        # We use this as a fast lookup table for the context of the request
        [Dictionary[Task[String], ComparableModuleSpecification]]$resolveTasks = @{}

        #We use this to track the tasks that are currently running
        #We dont need this to be ConcurrentList because we only manipulate it in the "main" runspace.
        [List[Task[String]]]$currentTasks = @()

        #This try finally is so that we can interrupt all http call tasks if Ctrl-C is pressed
        try {
            foreach ($moduleSpec in $ModulesToResolve) {
                $localMatch = Find-LocalModule $moduleSpec
                if ($localMatch) {
                    Write-Verbose "Found local module $localMatch that satisfies $moduleSpec. Skipping..."
                    #TODO: Capture this somewhere that we can use it to report in the deploy plan
                    continue
                }
                $task = Get-ModuleInfoAsync -Name $moduleSpec -HttpClient $httpclient -Uri $Source -CancellationToken $cancelToken.Token
                $resolveTasks[$task] = $moduleSpec
                $currentTasks.Add($task)
            }

            while ($currentTasks.Count -gt 0) {
                #The timeout here allow ctrl-C to continue working in PowerShell
                $noTasksYetCompleted = -1
                [int]$thisTaskIndex = [Task]::WaitAny($currentTasks, 500)
                if ($thisTaskIndex -eq $noTasksYetCompleted) { continue }

                #TODO: This only indicates headers were received, content may still be downloading and we dont want to block on that.
                #For now the content is small but this could be faster if we have another inner loop that WaitAny's on content
                #TODO: Perform a HEAD query to see if something has changed

                [Task[string]]$completedTask = $currentTasks[$thisTaskIndex]
                [ComparableModuleSpecification]$moduleSpec = $resolveTasks[$completedTask]

                Write-Debug "$moduleSpec`: Processing Response"
                # We use GetAwaiter so we get proper error messages back, as things such as network errors might occur here.
                #TODO: TryCatch logic for GetResult
                try {
                    $response = $completedTask.GetAwaiter().GetResult()
                    | ConvertFrom-Json
                } catch {
                    $taskException = $PSItem.Exception.InnerException
                    #TODO: Rewrite this as a handle filter
                    if ($taskException -isnot [HttpRequestException]) { throw }
                    [HttpRequestException]$err = $taskException
                    if ($err.StatusCode -eq [HttpStatusCode]::NotFound) {
                        throw [InvalidOperationException]"$moduleSpec`: module was not found in the $Source repository. Check the spelling and try again."
                    }

                    #All other cases
                    $PSItem.ErrorDetails = "$moduleSpec`: Failed to fetch module $moduleSpec from $Source. Error: $PSItem"
                    throw $PSItem
                }

                # HACK: Need to add @type to make this more discriminate between a direct version query and an individual item
                $responseItems = $response.catalogEntry ? $response.catalogEntry : $response.items.items.catalogEntry

                #TODO: This should be a separate function with a pipeline

                [Version[]]$candidateVersions = $responseItems.Version
                | Where-Object { -not $PSItem.contains('-') } #TODO: Support Prerelease

                $selectedVersion = Find-HighestSatisfiesVersion $moduleSpec $candidateVersions
                if (-not $selectedVersion) {
                    throw "No module that satisfies $moduleSpec was found in $Source"
                }

                $selectedModule = $responseItems | Where-Object Version -EQ $selectedVersion
                if ($selectedModule.count -ne 1) {
                    throw 'More than one selectedModule was specified. '
                }

                $moduleInfo = [ComparableModuleSpecification]@{
                    ModuleName      = $selectedModule.id
                    RequiredVersion = $selectedModule.version
                    #TODO: Fix in Server API GUID            = $moduleInfo.Guid
                }


                #Check if we have already processed this item and move on if we have
                if (-not $modulesToInstall.Add($moduleInfo)) {
                    Write-Debug "$moduleInfo ModulesToInstall already exists. Skipping..."
                    #TODO: Fix the flow so this isn't stated twice
                    [void]$resolveTasks.Remove($completedTask)
                    [void]$currentTasks.Remove($completedTask)
                    continue
                }

                Write-Verbose "$moduleInfo Added to ModulesToInstall."

                # HACK: Pwsh doesn't care about target framework as of today so we can skip that evaluation
                # TODO: Should it? Should we check for the target framework and only install if it matches?
                $dependencyInfo = $selectedModule.dependencyGroups.dependencies

                #Determine dependencies and add them to the pending tasks
                if ($dependencyInfo) {
                    # HACK: I should be using the Id provided by the server, for now I'm just guessing because
                    # I need to add it to the ComparableModuleSpec class
                    Write-Debug "$moduleSpec`: Processing dependencies"
                    try {
                        [List[ComparableModuleSpecification]]$dependencies = $dependencyInfo | Parse-NugetDependency

                    } catch { Wait-Debugger }
                    Write-Debug "$moduleSpec has $($dependencies.count) dependencies"

                    # TODO: Where loop filter maybe
                    [ComparableModuleSpecification[]]$dependenciesToResolve = $dependencies | Where-Object {
                        # TODO: This dependency resolution logic should be a separate function
                        # Maybe ModulesToInstall should be nested/grouped by Module Name then version to speed this up, as it currently
                        # enumerates every time which shouldn't be a big deal for small dependency trees but might be a
                        # meaninful performance difference on a whole-system upgrade.
                        [HashSet[string]]$moduleNames = $modulesToInstall.Name
                        if ($PSItem.Name -notin $ModuleNames) {
                            Write-Debug "$PSItem not already in ModulesToInstall. Resolving..."
                            return $true
                        }

                        $plannedVersions = $modulesToInstall
                        | Where-Object Name -EQ $PSItem.Name
                        | Sort-Object RequiredVersion -Descending

                        # TODO: Consolidate with Get-HighestSatisfiesVersion function
                        $highestPlannedVersion = $plannedVersions[0].RequiredVersion

                        if ($PSItem.Version -and ($PSItem.Version -gt $highestPlannedVersion)) {
                            Write-Debug "$($PSItem.Name): Minimum Version $($PSItem.Version) not satisfied by highest existing match $highestPlannedVersion. Performing Lookup."
                            return $true
                        }

                        if ($PSItem.MaximumVersion -and ($PSItem.MaximumVersion -lt $highestPlannedVersion)) {
                            Write-Debug "$($PSItem.Name): $highestPlannedVersion is higher than Maximum Version $($PSItem.MaximumVersion). Performing Lookup"
                            return $true
                        }

                        if ($PSItem.RequiredVersion -and ($PSItem.RequiredVersion -notin $plannedVersions.RequiredVersion)) {
                            Write-Debug "$($PSItem.Name): Explicity Required Version $($PSItem.RequiredVersion) is not within existing planned versions ($($plannedVersions.RequiredVersion -join ',')). Performing Lookup"
                            return $true
                        }

                        #If it didn't match, skip it
                        Write-Debug "$($PSItem.Name) dependency satisfied by $highestPlannedVersion already in the plan"
                    }

                    if (-not $dependenciesToResolve) {
                        Write-Debug "$moduleSpec has no remaining dependencies that need resolving"
                        continue
                    }

                    Write-Debug "Fetching info on remaining $($dependenciesToResolve.count) dependencies"

                    # We do this here rather than populate modulesToResolve because the tasks wont start until all the existing tasks complete
                    # TODO: Figure out a way to dedupe this logic maybe recursively but I guess a function would be fine too
                    foreach ($dependencySpec in $dependenciesToResolve) {
                        $localMatch = Find-LocalModule $dependencySpec
                        if ($localMatch) {
                            Write-Verbose "Found local module $localMatch that satisfies dependency $dependencySpec. Skipping..."
                            #TODO: Capture this somewhere that we can use it to report in the deploy plan
                            continue
                        }
                        # TODO: Deduplicate in-flight queries (az.accounts is a good example)
                        # Write-Debug "$moduleSpec`: Checking if $dependencySpec already has an in-flight request that satisfies the requirement"

                        Write-Debug "$moduleSpec`: Fetching dependency $dependencySpec"
                        $task = Get-ModuleInfoAsync -Name $dependencySpec -HttpClient $httpclient -Uri $Source -CancellationToken $cancelToken.Token
                        $resolveTasks[$task] = $dependencySpec
                        $currentTasks.Add($task)
                    }
                }
                try {
                    [void]$resolveTasks.Remove($completedTask)
                    [void]$currentTasks.Remove($completedTask)
                } catch {
                    throw
                }
                Write-Debug "Remaining Tasks: $($currentTasks.count)"
            }
        } finally {
            #This gets called even if ctrl-c occured during the process
            #Should cancel any outstanding requests
            if ($currentTasks.count -gt 0) {
                Write-Debug "Cancelling $($currentTasks.count) outstanding tasks"
            }

            $cancelToken.Dispose()
        }
        return $modulesToInstall
    }
}
# #endregion Main

#region Classes
<#
A custom version of ModuleSpecification that is comparable on its values, and will deduplicate in a HashSet if all
values are the same. This should also be consistent across processes and can be cached.
#>
class ComparableModuleSpecification : ModuleSpecification {
    ComparableModuleSpecification(): base() {}
    ComparableModuleSpecification([string]$moduleName): base($moduleName) {}
    ComparableModuleSpecification([hashtable]$moduleSpecification): base($moduleSpecification) {}
    hidden static [ComparableModuleSpecification] op_Implicit([ModuleSpecification]$spec) {
        return [ComparableModuleSpecification]@{
            Name            = $spec.Name
            Guid            = $spec.Guid
            Version         = $spec.Version
            RequiredVersion = $spec.RequiredVersion
            MaximumVersion  = $spec.MaximumVersion
        }
    }
    [ModuleSpecification] ToModuleSpecification() {
        return [ModuleSpecification]@{
            Name            = $this.Name
            Guid            = $this.Guid
            Version         = $this.Version
            RequiredVersion = $this.RequiredVersion
            MaximumVersion  = $this.MaximumVersion
        }
    }

    # Concatenate the properties into a string to generate a hashcode
    [int] GetHashCode() {
        return ($this.ToString()).GetHashCode()
    }
    [bool] Equals($obj) {
        return $this.GetHashCode().Equals($obj.GetHashCode())
    }
    [string] ToString() {
        return ($this.Name, $this.Guid, $this.Version, $this.MaximumVersion, $this.RequiredVersion -join ':')
    }
}
#endRegion Classes

#region Helpers
function New-NuGetPackageConfig ($modulesToInstall, $Path = [io.path]::GetTempFileName()) {
    $packageConfig = [xml.xmlwriter]::Create([string]$Path)
    $packageConfig.WriteStartDocument()
    $packageConfig.WriteStartElement('packages')
    foreach ($ModuleItem in $ModulesToInstall) {
        $packageConfig.WriteStartElement('package')
        $packageConfig.WriteAttributeString('id', $null, $ModuleItem.id)
        $packageConfig.WriteAttributeString('version', $null, $ModuleItem.Version)
        $packageConfig.WriteEndElement()
    }
    $packageConfig.WriteEndElement()
    $packageConfig.WriteEndDocument()
    $packageConfig.Flush()
    $packageConfig.Close()
    return $path
}

function Install-Modulefast {
    [CmdletBinding()]
    param(
        $ModulesToInstall,
        $Path,
        $ModuleCache = (New-Item -ItemType Directory -Force -Path (Join-Path ([io.path]::GetTempPath()) 'ModuleFastCache')),
        $NuGetCache = [io.path]::Combine([string[]]("$HOME", '.nuget', 'psgallery')),
        [Switch]$Force,
        #By default will modify your PSModulePath to use the builtin destination if not present. Setting this implicitly skips profile update as well.
        [Switch]$NoPSModulePathUpdate,
        #Setting this won't add the default destination to your profile.
        [Switch]$NoProfileUpdate
    )


    # Setup the Destination repository
    $defaultRepoPath = $(Join-Path ([Environment]::GetFolderPath()) 'powershell/modules')
    if (-not $Destination) {
        $Destination = $defaultRepoPath
    }
    # Autocreate the default as a convenience, otherwise require the path to be present to avoid mistakes
    if ($Destination -eq $defaultRepoPath -and -not (Test-Path $Destination)) {
        if ($PSCmdlet.ShouldProcess('Create Destination Folder', $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force
        }
    }
    # Should error if not present
    $Destination = Resolve-Path $Destination

    if ($Destination -ne $defaultRepoPath) {
        if (-not $NoProfileUpdate) {
            Write-Warning 'Parameter -Destination is set to a custom path. We assume you know what you are doing, so it will not automatically be added to your Profile but will be added to PSModulePath. Set -NoProfileUpdate to suppress this message in the future.'
        }
        $NoProfileUpdate = $true
    }
    if (-not $NoPSModulePathUpdate) {
        $pathUpdateMessage = "Update PSModulePath $($NoProfileUpdate ? '' : 'and CurrentUserAllHosts profile ')to include $Destination"
        if (-not $PSCmdlet.ShouldProcess($pathUpdateMessage)) { return }

        Add-DestinationToPSModulePath -Destination $Destination -NoProfileUpdate:$NoProfileUpdate

    }

    #Do a really crappy guess for the current user modules folder.
    #TODO: "Scope CurrentUser" type logic
    if (-not $Path) {
        if (-not $env:PSModulePath) { throw 'PSModulePath is not defined, therefore the -Path parameter is mandatory' }
        $envSeparator = ';'
        if ($isLinux) { $envSeparator = ':' }
        $Path = ($env:PSModulePath -split $envSeparator)[0]
    }

    if (-not $httpclient) { $SCRIPT:httpClient = [Net.Http.HttpClient]::new() }
    $baseURI = 'https://www.powershellgallery.com/api/v2/package/'
    Write-Progress -Id 1 -Activity 'Install-Modulefast' -Status "Creating Download Tasks for $($ModulesToInstall.count) modules"
    $DownloadTasks = foreach ($ModuleItem in $ModulesToInstall) {
        $ModulePackageName = @($ModuleItem.Id, $ModuleItem.Version, 'nupkg') -join '.'
        $ModuleCachePath = [io.path]::Combine(
            [string[]](
                $NuGetCache,
                $ModuleItem.Id,
                $ModuleItem.Version,
                $ModulePackageName
            )
        )
        #TODO: Remove Me
        $ModuleCachePath = "$ModuleCache/$ModulePackageName"
        #$uri = $baseuri + $ModuleName + '/' + $ModuleVersion
        [void][io.directory]::CreateDirectory((Split-Path $ModuleCachePath))
        $ModulePackageTempFile = [io.file]::Create($ModuleCachePath)
        $DownloadTask = $httpclient.GetStreamAsync($ModuleItem.Source)

        #Return a hashtable with the task and file handle which we will need later
        @{
            DownloadTask = $DownloadTask
            FileHandle   = $ModulePackageTempFile
        }
    }

    #NOTE: This seems to go much faster when it's not in the same foreach as above, no idea why, seems to be blocking on the call
    $downloadTasks = $DownloadTasks.Foreach{
        $PSItem.CopyTask = $PSItem.DownloadTask.result.CopyToAsync($PSItem.FileHandle)
        return $PSItem
    }

    #TODO: Add timeout via Stopwatch
    [array]$CopyTasks = $DownloadTasks.CopyTask
    while ($false -in $CopyTasks.iscompleted) {
        [int]$remainingTasks = ($CopyTasks | Where-Object iscompleted -EQ $false).count
        $progressParams = @{
            Id               = 1
            Activity         = 'Install-Modulefast'
            Status           = "Downloading $($CopyTasks.count) Modules"
            CurrentOperation = "$remainingTasks Modules Remaining"
            PercentComplete  = [int](($CopyTasks.count - $remainingtasks) / $CopyTasks.count * 100)
        }
        Write-Progress @ProgressParams
        Start-Sleep 0.2
    }

    $failedDownloads = $downloadTasks.downloadtask.where{ $PSItem.isfaulted }
    if ($failedDownloads) {
        #TODO: More comprehensive error message
        throw "$($failedDownloads.count) files failed to download. Aborting"
    }

    $failedCopyTasks = $downloadTasks.copytask.where{ $PSItem.isfaulted }
    if ($failedCopyTasks) {
        #TODO: More comprehensive error message
        throw "$($failedCopyTasks.count) files failed to copy. Aborting"
    }

    #Release the files once done downloading. If you don't do this powershell may keep a file locked.
    $DownloadTasks.FileHandle.close()

    #Cleanup
    #TODO: Cleanup should be in a trap or try/catch
    $DownloadTasks.DownloadTask.dispose()
    $DownloadTasks.CopyTask.dispose()
    $DownloadTasks.FileHandle.dispose()

    #Unpack the files
    Write-Progress -Id 1 -Activity 'Install-Modulefast' -Status "Extracting $($modulestoinstall.id.count) Modules"
    $packageConfigPath = Join-Path $ModuleCache 'packages.config'
    if (Test-Path $packageConfigPath) { Remove-Item $packageConfigPath }
    $packageConfig = New-NuGetPackageConfig -modulesToInstall $ModulesToInstall -path $packageConfigPath

    $timer = [diagnostics.stopwatch]::startnew()
    $moduleCount = $modulestoinstall.id.count
    $ipackage = 0
    #Initialize the files in the repository, if relevant
    & nuget.exe init $ModuleCache $NugetCache | Where-Object { $PSItem -match 'already exists|installing' } | ForEach-Object {
        if ($ipackage -lt $modulecount) { $ipackage++ }
        #Write-Progress has a performance issue if run too frequently
        if ($timer.elapsedmilliseconds -gt 200) {
            $progressParams = @{
                id               = 1
                Activity         = 'Install-Modulefast'
                Status           = "Extracting $modulecount Modules"
                CurrentOperation = "$ipackage of $modulecount Remaining"
                PercentComplete  = [int]($ipackage / $modulecount * 100)
            }
            Write-Progress @progressParams
            $timer.restart()
        }
    }
    if ($LASTEXITCODE) { throw 'There was a problem with nuget.exe' }

    #Create symbolic links from the nuget repository to "install" the packages
    foreach ($moduleItem in $modulesToInstall) {
        $moduleRelativePath = [io.path]::Combine($ModuleItem.id, $moduleitem.version)
        #nuget saves as lowercase, matching to avoid Linux case issues
        $moduleNugetPath = (Join-Path $NugetCache $moduleRelativePath).tolower()
        $moduleTargetPath = Join-Path $Path $moduleRelativePath

        if (-not (Test-Path $moduleNugetPath)) { Write-Error "$moduleNugetPath doesn't exist"; continue }
        if (-not (Test-Path $moduleTargetPath) -and -not $force) {
            $ModuleFolder = (Split-Path $moduleTargetPath)
            #Create the parent target folder (as well as any hierarchy) if it doesn't exist
            [void][io.directory]::createdirectory($ModuleFolder)

            #Create a symlink to the module in the package repository
            if ($PSCmdlet.ShouldProcess($moduleTargetPath, "Install Powershell Module $($ModuleItem.id) $($moduleitem.version)")) {
                $null = New-Item -ItemType SymbolicLink -Path $ModuleFolder -Name $moduleitem.version -Value $moduleNugetPath
            }
        } else {
            Write-Verbose "$moduleTargetPath already exists"
        }
        #Create the parent target folder if it doesn't exist
        #[io.directory]::createdirectory($moduleTargetPath)
    }
}

filter Get-ModuleInfoAsync {
    [CmdletBinding()]
    [OutputType([Task[String]])]
    param (
        [Parameter(Mandatory)][ComparableModuleSpecification]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][HttpClient]$HttpClient,
        [CancellationToken]$CancellationToken
    )
    end {
        $moduleSpec = $Name
        $ModuleId = $ModuleSpec.Name

        #Strip any *.json path which might be at the end of the uri
        $endpoint = $Uri -replace '/\w+\.json$'

        #HACK: We are making a *big* assumption here about the structure of the nuget repository to save an API call
        #TODO: Error handling if we are wrong by checking the main index.json manifest

        if ($Name.MaximumVersion) {
            throw [NotImplementedException]"$Name has a maximum version. This is not implemented yet."
        }
        $moduleInfoUriBase = "$endpoint/registration/$ModuleId"
        if ($moduleSpec.RequiredVersion) {
            $moduleInfoUri = "$moduleInfoUriBase/$($moduleSpec.RequiredVersion).json"
        } else {
            $moduleInfoUri = "$moduleInfoUriBase/index.json"
        }

        #TODO: System.Text.JSON serialize this with fancy generic methods in 7.3?
        Write-Debug "$ModuleId`: fetch info from $moduleInfoUri"
        return $HttpClient.GetStringAsync($moduleInfoUri, $CancellationToken)
    }
}

filter Parse-NugetDependency ([Parameter(Mandatory, ValueFromPipeline)]$Dependency) {
    #TODO: Dependency should be more strictly typed

    #NOTE: This can't be a modulespecification from the start because modulespecs are immutable
    $dep = @{
        ModuleName = $Dependency.id
    }
    $Version = $Dependency.range

    # Treat a null result as "any"
    if ([String]::IsNullOrEmpty($Version)) {
        $dep.ModuleVersion = '0.0.0'
        return [ComparableModuleSpecification]$dep
    }

    #If it is a direct module specification, treat this as a required version.
    $exactVersion = $null
    if ([Version]::TryParse($Version, [ref]$exactVersion)) {
        $dep.RequiredVersion = $exactVersion
        return [ComparableModuleSpecification]$dep
    }

    #If it is an open bound, set ModuleVersion to 0.0.0 (meaning any version)
    if ($version -eq '(, )') {
        $dep.ModuleVersion = '0.0.0'
        return [ComparableModuleSpecification]$dep
    }

    #If it is an exact match version (has brackets and doesn't have a comma), set version accordingly
    $ExactVersionRegex = '\[([^,]+)\]'
    if ($version -match $ExactVersionRegex) {
        $dep.RequiredVersion = $matches[1]
        return [ComparableModuleSpecification]$dep
    }

    #Parse all other remainder options. For this purpose we ignore inclusive vs. exclusive
    #TODO: Add inclusive/exclusive parsing
    $version = $version -replace '[\[\(\)\]]', '' -split ','

    $minimumVersion = $version[0].trim()
    $maximumVersion = $version[1].trim()
    if ($minimumVersion -and $maximumVersion -and ($minimumVersion -eq $maximumVersion)) {
        #If the minimum and maximum versions match, we treat this as an explicit version
        $dep.RequiredVersion = $minimumVersion
        return [ComparableModuleSpecification]$dep
    } elseif ($minimumVersion -or $maximumVersion) {
        if ($minimumVersion) { $dep.ModuleVersion = $minimumVersion }
        if ($maximumVersion) { $dep.MaximumVersion = $maximumVersion }
    } else {
        #If no matching version works, just set dep to a string of the modulename
        Write-Warning "$($dep.ModuleName) has an invalid version spec, falling back to maximum version."
    }

    return [ComparableModuleSpecification]$dep
}

<#
.SYNOPSIS
Adds an existing PowerShell Modules path to the current session as well as the profile
#>
function Add-DestinationToPSModulePath ([string]$Destination, [switch]$NoProfileUpdate) {
    $ErrorActionPreference = 'Stop'
    $Destination = Resolve-Path $Destination #Will error if it doesn't exist

    $env:PSModulePath = $Destination + [Path]::PathSeparator + $env:PSModulePath

    # Check if the destination is in the PSModulePath
    [string[]]$modulePaths = $env:PSModulePath -split [Path]::PathSeparator

    if ($Destination -notin $modulePaths) {
        Write-Warning "$Destination is not in current PSModulePath list. Adding to both the current session and Current User All Hosts profile."
        $modulePaths += $Destination
        $env:PSModulePath = $modulePaths -join [Path]::PathSeparator

        if (-not $NoProfileUpdate) {
            $myProfile = $profile.CurrentUserAllHosts
            if (-not (Test-Path $myProfile)) {
                Write-Verbose 'User All Hosts profile not found, creating one.'
                New-Item -ItemType File -Path $Destination -Force
            }
            $ProfileLine = "`$env:PSModulePath += [System.IO.Path]::PathSeparator + $Destination #Added by ModuleFast. If you dont want this, add -NoProfileUpdate to your command."
            #FIXME: Complete this when I get to the Install-Module part
            # if (Get-Content -Raw $Profile) -notmatch
            Add-Content -Path $profile -Value "`$env:PSModulePath += ';$Destination'"
        } else {
            Write-Warning 'The module repository is not in your PSModulePath. Please add it to use the modules.'
        }
    }
}

<#
.SYNOPSIS
Searches local PSModulePath repositories
#>
function Find-LocalModule {
    param(
        [Parameter(Mandatory)][ComparableModuleSpecification]$ModuleSpec,
        [string[]]$ModulePath = $($env:PSModulePath -split [Path]::PathSeparator)
    )
    $ErrorActionPreference = 'Stop'
    # BUG: Prerelease Module paths are still not recognized by internal PS commands and can break things

    # Search all psmodulepaths for the module
    $modulePaths = $env:PSModulePath -split [Path]::PathSeparator

    # NOTE: We are intentionally using return instead of continue here, as soon as we find a match we are done.
    foreach ($modulePath in $modulePaths) {
        if ($moduleSpec.RequiredVersion) {
            #We can speed up the search for explicit requiredVersion matches
            #HACK: We assume a release version can satisfy a prerelease version constraint here.
            $manifestPath = Join-Path $modulePath $ModuleSpec.Name $([Version]$ModuleSpec.RequiredVersion) "$($ModuleSpec.Name).psd1"
            if ([File]::Exists($manifestPath)) { return $manifestPath }
        } else {
            #Get all the version folders for the moduleName
            $moduleNamePath = Join-Path $modulePath $ModuleSpec.Name
            if (-not ([Directory]::Exists($moduleNamePath))) { continue }
            $folders = [System.IO.Directory]::GetDirectories($moduleNamePath) | Split-Path -Leaf
            [Version[]]$candidateVersions = foreach ($folder in $folders) {
                [Version]$version = $null
                if ([Version]::TryParse($folder, [ref]$version)) { $version } else {
                    Write-Warning "Could not parse $folder in $moduleNamePath as a valid version. This is probably a bad module directory and should be removed."
                }
            }

            if (-not $candidateVersions) {
                Write-Verbose "$moduleSpec`: module folder exists at $moduleNamePath but no modules found that match the version spec."
                continue
            }
            $versionMatch = Find-HighestSatisfiesVersion -ModuleSpec $ModuleSpec -Version $candidateVersions
            if ($versionMatch) {
                $manifestPath = Join-Path $moduleNamePath $([Version]$versionMatch) "$($ModuleSpec.Name).psd1"
                if (-not [File]::Exists($manifestPath)) {
                    # Our matching method doesn't make it easy to match on "next highest" version, so we have to do this.
                    throw "A matching module folder was found for $ModuleSpec but the manifest is not present at $manifestPath. This indicates a corrupt module and should be removed before proceeding."
                } else {
                    return $manifestPath
                }
            }
        }
    }

    return $false
}

<#
Given an array of versions, find the highest one that satisfies the module spec. Returns $false if no match is found.
#>
function Find-HighestSatisfiesVersion {
    param(
        [Parameter(Mandatory)][ComparableModuleSpecification]$ModuleSpec,
        #Versions that are potential candidates to satisfy the modulespec
        [Parameter(Mandatory)][HashSet[Version]]$Versions
    )
    # TODO: Semver-compatible version of this function

    # RequiredVersion is an easy explicit compare
    if ($ModuleSpec.RequiredVersion) {
        if ($Versions.Contains($ModuleSpec.RequiredVersion)) {
            return $ModuleSpec.RequiredVersion
        } else {
            return $false
        }
    }

    $candidateVersions = foreach ($version in $versions) {
        if ($ModuleSpec.MaximumVersion -and $version -gt $ModuleSpec.MaximumVersion) { continue }
        if ($ModuleSpec.Version -and $version -lt $ModuleSpec.Version) { continue }
        $version
    }

    $highestFilteredVersion = $candidateVersions
    | Sort-Object -Descending
    | Select-Object -First 1

    if ($highestFilteredVersion) {
        return $highestFilteredVersion
    } else {
        return $false
    }
}

#BUG: This is required because the SMA.SemanticVersion class cannot handle build (+) by itself
#https://github.com/PowerShell/PowerShell/issues/14605
function ConvertTo-Version([SemanticVersion]$Version, [string]$BuildHint = 'SEMBUILD') {
    if ($null -eq ($Version.BuildLabel -as [int])) {
        Write-Warning [InvalidDataException]"BuildLabel $($Version.BuildLabel) is not numeric and cannot be cast, and will be skipped."
        [Version]::new($Version.Major, $Version.Minor, $Version.Patch)
    }
    [Version]::new($Version.Major, $Version.Minor, $Version.Patch)
}

#endregion Helpers

# Export-ModuleMember Get-ModuleFast


### ISSUES
# FIXME: When doing directory match comparison for local modules, need to preserve original folder name. See: Reflection 4.8
# FIXME: DBops dependency version issue
# FIXME: Dependency range when it is just a version number with a really high build - Vmware.Vimautomation.core 10.0.0.xxxxxxxx
# FIXME: Semver and 4 octet modules are incompatible, need to handle this