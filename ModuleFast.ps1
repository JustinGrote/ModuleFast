#requires -version 7.2
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
        [HashSet[ModuleFastSpec]]$modulesToResolve = @()

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

        #We pass this splat to all our HTTP requests to cut down on boilerplate
        $httpContext = @{
            HttpClient        = $httpClient
            CancellationToken = $cancelToken.Token
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
        # A deduplicated list of modules to install
        [HashSet[ModuleFastSpec]]$modulesToInstall = @{}

        # We use this as a fast lookup table for the context of the request
        [Dictionary[Task[String], ModuleFastSpec]]$resolveTasks = @{}

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
                $task = Get-ModuleInfoAsync @httpContext -Endpoint $Source -Name $moduleSpec.Name
                $resolveTasks[$task] = $moduleSpec
                $currentTasks.Add($task)
            }

            while ($currentTasks.Count -gt 0) {
                #The timeout here allow ctrl-C to continue working in PowerShell
                #-1 is returned by WaitAny if we hit the timeout before any tasks completed
                $noTasksYetCompleted = -1
                [int]$thisTaskIndex = [Task]::WaitAny($currentTasks, 500)
                if ($thisTaskIndex -eq $noTasksYetCompleted) { continue }

                #TODO: This only indicates headers were received, content may still be downloading and we dont want to block on that.
                #For now the content is small but this could be faster if we have another inner loop that WaitAny's on content
                #TODO: Perform a HEAD query to see if something has changed

                [Task[string]]$completedTask = $currentTasks[$thisTaskIndex]
                [ModuleFastSpec]$currentModuleSpec = $resolveTasks[$completedTask]

                Write-Debug "$currentModuleSpec`: Processing Response"
                # We use GetAwaiter so we get proper error messages back, as things such as network errors might occur here.
                #TODO: TryCatch logic for GetResult
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

                #HACK: Add the download URI to the catalog entry, this makes life easier.
                $pageLeaves = $response.items.items
                $pageLeaves | ForEach-Object {
                    if ($PSItem.packageContent) {
                        $PSItem.catalogEntry
                        | Add-Member -NotePropertyName 'PackageContent' -NotePropertyValue $PSItem.packageContent
                    }
                }

                $entries = $pageLeaves.catalogEntry
                [version[]]$inlinedVersions = $entries.version
                | Where-Object {
                    $PSItem -and !$PSItem.contains('-')
                }

                # FIXME: Replace with Overlap
                [Version]$versionMatch = Limit-ModuleFastSpecVersions -ModuleSpec $currentModuleSpec -Highest -Versions $inlinedVersions


                if ($versionMatch) {
                    Write-Debug "$currentModuleSpec`: Found satisfying version $versionMatch in the inlined index. TODO: Resolve dependencies"
                    $selectedEntry = $entries | Where-Object version -EQ $versionMatch
                    #TODO: Resolve dependencies in separate function
                } else {
                    #Do a more detailed resolution
                    Write-Debug "$currentModuleSpec`: not found in inlined index. Determining appropriate page(s) to query"
                    #If not inlined, we need to find what page(s) might have the candidate info we are looking for.
                    #While this may seem inefficient, all pages but latest are static and have a long lifetime so we trade a
                    #longer cold start to a nearly infinite requery, which will handle all subsequent dependency lookups.
                    #stats show most modules have a few common dependencies, so caching all versions of those dependencies is
                    #very helpful for fast performance

                    # HACK: Need to add @type to make this more discriminate between a direct version query and an individual item
                    # TODO: Should probably typesafe and validate this using classes

                    $pages = $response.items | Where-Object {
                        [Version]$upper = $PSItem.Upper
                        [Version]$lower = $PSItem.Lower
                        if ($currentModuleSpec.Required) {
                            if ($currentModuleSpec.Required -le $upper -and $currentModuleSpec.Required -ge $lower ) {
                                return $true
                            }
                        } else {
                            [version]$min = $currentModuleSpec.Version ?? '0.0.0'
                            [version]$max = $currentModuleSpec.MaximumVersion ?? '{0}.{0}.{0}.{0}' -f [Int32]::MaxValue
                            #Min and Max are outside the range (meaning the range is inside the min and max)
                            if ($min -le $lower -and $max -ge $upper) {
                                return $true
                            }
                            #Min or max is in range (partial worth exploring)
                            if ($min -ge $lower -and $min -le $upper) {
                                return $true
                            }
                            #Max is in range (partial worth exploring)
                            if ($max -ge $lower -and $max -le $upper) {
                                return $true
                            }
                            #Otherwise there is no match
                        }
                    }

                    if (-not $pages) {
                        throw [InvalidOperationException]"$currentModuleSpec`: a matching module was not found in the $Source repository that satisfies the version constraints. If this happens during dependency lookup, it is a bug in ModuleFast."
                    }
                    Write-Debug "$currentModuleSpec`: Found $($pages.Count) additional pages that might match the query."

                    #TODO: This is relatively slow and blocking, but we would need complicated logic to process it in the main task handler loop.
                    #I really should make a pipeline that breaks off tasks based on the type of the response.
                    #This should be a relatively rare query that only happens when the latest package isn't being resolved.
                    [Task[string][]]$tasks = foreach ($page in $pages) {
                        Get-ModuleInfoAsync @httpContext -Uri $page.'@id'
                        #This loop is here to support ctrl-c cancellation again
                    }
                    while ($false -in $tasks.IsCompleted) {
                        [void][Task]::WaitAll($tasks, 500)
                    }
                    $entries = ($tasks.GetAwaiter().GetResult() | ConvertFrom-Json).items.catalogEntry

                    # TODO: Dedupe this logic with the above
                    [HashSet[Version]]$inlinedVersions = $entries.version
                    | Where-Object {
                        $PSItem -and !$PSItem.contains('-')
                    }

                    [Version]$versionMatch = Limit-ModuleFastSpecVersions -ModuleSpec $moduleSpec -Versions $inlinedVersions -Highest
                    if ($versionMatch) {
                        Write-Debug "$currentModuleSpec`: Found satisfying version $versionMatch in one of the additional pages."
                        $selectedEntry = $entries | Where-Object version -EQ $versionMatch
                        #TODO: Resolve dependencies in separate function
                    }
                }

                if ($selectedEntry.count -ne 1) {
                    throw 'Something other than exactly 1 selectedModule was specified. This should never happen and is a bug'
                }

                [ModuleFastSpec]$moduleInfo = [ModuleFastSpec]::new(
                    $selectedEntry.id,
                    $selectedEntry.version,
                    [uri]$selectedEntry.packageContent
                )

                #Check if we have already processed this item and move on if we have
                if (-not $modulesToInstall.Add($moduleInfo)) {
                    Write-Debug "$moduleInfo ModulesToInstall already exists. Skipping..."
                    #TODO: Fix the flow so this isn't stated twice
                    [void]$resolveTasks.Remove($completedTask)
                    [void]$currentTasks.Remove($completedTask)
                    continue
                }

                Write-Debug "$moduleInfo Added to ModulesToInstall."

                # HACK: Pwsh doesn't care about target framework as of today so we can skip that evaluation
                # TODO: Should it? Should we check for the target framework and only install if it matches?
                $dependencyInfo = $selectedEntry.dependencyGroups.dependencies

                #Determine dependencies and add them to the pending tasks
                if ($dependencyInfo) {
                    # HACK: I should be using the Id provided by the server, for now I'm just guessing because
                    # I need to add it to the ComparableModuleSpec class
                    Write-Debug "$currentModuleSpec`: Processing dependencies"
                    [List[ModuleFastSpec]]$dependencies = $dependencyInfo | Parse-NugetDependency
                    Write-Debug "$currentModuleSpec has $($dependencies.count) dependencies"

                    # TODO: Where loop filter maybe
                    [ModuleFastSpec[]]$dependenciesToResolve = $dependencies | Where-Object {
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

                        Write-Debug "$currentModuleSpec`: Fetching dependency $dependencySpec"
                        $task = Get-ModuleInfoAsync @httpContext -Endpoint $Source -Name $dependencySpec.Name
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

# Use invoke-webrequest outfile to save every modulespec to the modules directory


# Parallel

function Install-Modulefast {
    [CmdletBinding(SupportsShouldProcess)]
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


# #endregion Main

#region PlanHelpers
#endregion PlanHelpers




#region Classes

<#
A custom version of ModuleSpecification that is comparable on its values, and will deduplicate in a HashSet if all
values are the same. This should also be consistent across processes and can be cached.

The version and semantic version classes allow nulls in way too many locations, and requiredmodule is redundant with
setting min and max the same.

It is somewhat non-null that can be used to compare modules but it should really be immutable. I really should make a C# version for this.
#>

class ModuleFastSpec : IComparable {

    static [SemanticVersion]$MinVersion = 0
    static [SemanticVersion]$MaxVersion = '{0}.{0}.{0}' -f [int32]::MaxValue
    #Special string we use to translate between Version and SemanticVersion since SemanticVersion doesnt support Semver 2.0 properly and doesnt allow + only
    #Someone actually using this string may cause a conflict, it's not foolproof but it's better than nothing
    static [string]$VersionBuildIdentifier = 'MFbuild'
    hidden static [string]$buildVersionRegex = '^\d+\.\d+\.\d+\.\d+$'

    #These properties are effectively read only thanks to some wizardry
    hidden [uri]$_DownloadLink
    hidden [uri]Get_DownloadLink() { return $this._DownloadLink }
    hidden [string]$_Name
    hidden [string]Get_Name() { return $this._Name }
    hidden [guid]$_Guid
    hidden [guid]Get_Guid() { return $this._Guid }
    hidden [SemanticVersion]$_Min = [ModuleFastSpec]::MinVersion
    hidden [SemanticVersion]Get_Min() { return $this._Min }
    hidden [SemanticVersion]$_Max = [ModuleFastSpec]::MaxVersion
    hidden [SemanticVersion]Get_Max() { return $this._Max }

    hidden [SemanticVersion]Get_Required() {
        if ($this.Min -eq $this.Max) {
            return $this.Min
        } else {
            return $null
        }
    }

    #ModuleSpecification Compatible Aliases
    hidden [SemanticVersion]Get_RequiredVersion() { return $this.Required }
    hidden [SemanticVersion]Get_Version() { return $this.Min }
    hidden [SemanticVersion]Get_MaximumVersion() { return $this.Max }

    #Constructors

    #HACK: A helper because we can't do constructor chaining in PowerShell
    #https://stackoverflow.com/questions/44413206/constructor-chaining-in-powershell-call-other-constructors-in-the-same-class
    #HACK: Guid and SemanticVersion are non-nullable and just causes problems trying to enforce it here, we make sure it doesn't get set to a null value later on
    hidden Initialize([string]$Name, $Min, $Max, $Guid, [ModuleSpecification]$moduleSpec) {
        Add-Getters

        #Explode out moduleSpec information if present and then follow the same validation logic
        if ($moduleSpec) {
            $Name = $ModuleSpec.Name
            $Guid = $ModuleSpec.Guid
            if ($ModuleSpec.RequiredVersion) {
                $Min = [ModuleFastSpec]::ParseVersionString($ModuleSpec.RequiredVersion)
                $Max = [ModuleFastSpec]::ParseVersionString($ModuleSpec.RequiredVersion)
            } else {
                $Min = $moduleSpec.Version ? [ModuleFastSpec]::ParseVersionString($ModuleSpec.Version) : $null
                $Max = $moduleSpec.MaximumVersion ? [ModuleFastSpec]::ParseVersionString($ModuleSpec.MaximumVersion) : $null
            }
        }

        #HACK: The nulls here are just to satisfy the ternary operator, they go off into the ether and arent returned or used
        $Name ? ($this._Name = $Name) : $null
        $Min ? ($this._Min = $Min) : $null
        $Max ? ($this._Max = $Max) : $null
        $Guid ? ($this._Guid = $Guid) : $null
        if ($this.Guid -ne [Guid]::Empty -and -not $this.Required) {
            throw 'Cannot specify Guid unless min and max are the same. If you see this, it is probably a bug'
        }
    }

    # HACK: We dont want a string constructor because it messes with Equals (we dont want strings implicitly cast to ModuleFastSpec).
    # ModuleName is a workaround for this and still make it easy to define a spec that matches all versions of a module.
    ModuleFastSpec([string]$Name) {
        $this.Initialize($Name, $null, $null, $null, $null)
    }
    ModuleFastSpec([string]$Name, [string]$Required) {
        [SemanticVersion]$requiredVersion = [ModuleFastSpec]::ParseVersionString($Required)
        $this.Initialize($Name, $requiredVersion, $requiredVersion, $null, $null)
    }
    ModuleFastSpec([string]$Name, [String]$Required, [Guid]$Guid) {
        [SemanticVersion]$requiredVersion = [ModuleFastSpec]::ParseVersionString($Required)
        $this.Initialize($Name, $requiredVersion, $requiredVersion, $Guid, $null)
    }
    ModuleFastSpec([string]$Name, [String]$Required, [Uri]$DownloadLink) {
        [SemanticVersion]$requiredVersion = [ModuleFastSpec]::ParseVersionString($Required)
        $this.Initialize($Name, $requiredVersion, $requiredVersion, $null, $null)
        $this._DownloadLink = [uri]$DownloadLink
    }

    ModuleFastSpec([string]$Name, [string]$Min, [string]$Max) {
        [SemanticVersion]$minVer = $min ? [ModuleFastSpec]::ParseVersionString($min) : $null
        [SemanticVersion]$maxVer = $max ? [ModuleFastSpec]::ParseVersionString($max) : $null
        $this.Initialize($Name, $minVer, $maxVer, $null, $null)
    }


    # These can be used for performance to avoid parsing to string and back. Probably makes little difference
    ModuleFastSpec([string]$Name, [SemanticVersion]$Required) {
        $this.Initialize($Name, $Required, $Required, $null, $null)
    }



    #TODO: Version versions maybe? Probably should just use the parser and let those go to string

    ModuleFastSpec([ModuleSpecification]$ModuleSpec) {
        $this.Initialize($null, $null, $null, $null, $ModuleSpec)
    }

    #Hashtable constructor works the same as for moduleSpecification for ease of use/understanding
    ModuleFastSpec([hashtable]$hashtable) {
        #Will implicitly convert the hashtable to ModuleSpecification
        $this.Initialize($null, $null, $null, $null, $hashtable)
    }

    ### Version Helper Methods
    #Determines if a version is within range of the spec.
    [bool] Matches ([SemanticVersion]$Version) {
        if ($null -eq $Version) { return $false }
        if ($Version -ge $this.Min -and $Version -le $this.Max) { return $true }
        return $false
    }
    [bool] Matches ([Version]$Version) {
        return $this.Matches([ModuleFastSpec]::ParseVersion($Version))
    }
    [bool] Matches ([String]$Version) {
        return $this.Matches([ModuleFastSpec]::ParseVersionString($Version))
    }

    #Determines if this spec is at least partially inside of the supplied spec
    [bool] Overlaps ([ModuleFastSpec]$Spec) {
        if ($null -eq $Spec) { return $false }
        if ($Spec.Name -ne $this.Name) { throw "Supplied Spec Name $($Spec.Name) does not match this spec name $($this.Name)" }
        if ($Spec.Guid -ne $this.Guid) { throw "Supplied Spec Guid $($Spec.Name) does not match this spec guid $($this.Name)" }

        # Returns true if there is any overlap between $this and $spec
        if ($this.Min -lt $Spec.Max -and $this.Max -gt $Spec.Min) { return $true }
        return $false
    }

    # Parses either a assembly version or semver to a semver string
    static [SemanticVersion] ParseVersionString([string]$Version) {
        if ($null -eq $Version) { return $null }
        $result = if ($Version -match [ModuleFastSpec]::buildVersionRegex) {
            [ModuleFastSpec]::ParseVersion($Version)
        } else { $Version }
        return $result
    }

    # A version number with 4 octets wont cast to semanticversion properly, this is a helper method for that.
    # We treat "revision" as "build" and "build" as patch for purposes of translation
    # Needed because SemVer can't parse builds correctly
    #https://github.com/PowerShell/PowerShell/issues/14605
    static [SemanticVersion]ParseVersion([Version]$Version) {
        if ($null -eq $Version) { return $null }

        if ($Version.Revision -ge 0) {
            [SemanticVersion]::new(
                $Version.Major,
                $Version.Minor -eq -1 ? 0 : $Version.Minor,
                $Version.Build -eq -1 ? 0 : $Version.Build,
                [ModuleFastSpec]::VersionBuildIdentifier,
                $Version.Revision
            )
        } else {
            [SemanticVersion]::new(
                $Version.Major,
                $Version.Minor -eq -1 ? 0 : $Version.Minor,
                $Version.Build -eq -1 ? 0 : $Version.Build
            )
        }
        $versionWith4SectionsRegex = '^\d+\.\d+\.\d+\.\d+$'
        $parsedVersion = $Version -match $versionWith4SectionsRegex `
            ? '{0}.{1}.{2}-{4}+{3}' -f $Version.Major, $Version.Minor, $Version.Build, $Version.Revision, [ModuleFastSpec]::VersionBuildIdentifier
        : $Version
        return [SemanticVersion]$parsedVersion
    }

    # A way to go back from SemanticVersion
    static [Version]ParseSemanticVersion([SemanticVersion]$Version) {
        if ($null -eq $Version) { return $null }
        return [Version]('{0}.{1}.{2}{3}' -f
            $Version.Major,
            ($Version.Minor ?? 0),
            ($Version.Patch ?? 0),
            (($Version.PreReleaseLabel -eq [ModuleFastSpec]::VersionBuildIdentifier -and $Version.BuildLabel -gt 0) ? ".$($Version.BuildLabel)" : $null)
        )
    }
    [Version] ToVersion() {
        if (-not $this.Required) { throw [NotSupportedException]'You can only convert Required specs to a version.' }
        #Warning: Return type is not enforced by the method, that's why we did it explicitly here.
        return [Version][ModuleFastSpec]::ParseSemanticVersion($this.Required)
    }


    ###Implicit Methods

    #This string will be unique for each spec type, and can (probably)? Be safely used as a hashcode
    #TODO: Implement parsing of this string to the parser to allow it to be "reserialized" to a module spec
    [string]ToString() {
        $name = $this._Name + ($this._Guid -ne [Guid]::Empty ? " [$($this._Guid)]" : '')
        $versionString = switch ($true) {
            ($this.Min -eq [ModuleFastSpec]::MinVersion -and $this.Max -eq [ModuleFastSpec]::MaxVersion) {
                #This is the default, so we don't need to print it
                break
            }
            ($this.required) { "@$($this.Required)"; break }
            ($this.Min -eq [ModuleFastSpec]::MinVersion) { "<$($this.Max)"; break }
            ($this.Max -eq [ModuleFastSpec]::MaxVersion) { ">$($this.Min)"; break }
            default { ":$($this.Min)-$($this.Max)" }
        }
        return $name + $versionString
    }

    #BUG: We cannot implement IEquatable directly because we need to self-reference ModuleFastSpec before it exists.
    #We can however just add Equals() method

    #Implementation of https://learn.microsoft.com/en-us/dotnet/api/system.iequatable-1.equals?view=net-6.0
    [boolean] Equals ([Object]$obj) {
        if ($null -eq $obj) { return $false }
        switch ($obj.GetType()) {
            #Comparing ModuleSpecs means that we want to ensure they are structurally the same
            ([ModuleFastSpec]) {
                return $this.Name -eq $obj.Name -and
                $this.Guid -eq $obj.Guid -and
                $obj.Min -ge $this.Min -and
                $obj.Max -le $this.Max
            }
            ([ModuleSpecification]) { return $this.Equals([ModuleFastSpec]$obj) }

            #When comparing a version, we want to return equal if the version is within the range of the spec
            ([SemanticVersion]) { return $this.CompareTo($obj) -eq 0 }
            ([string]) { return $this.Equals([ModuleFastSpec]::ParseVersionString($obj)) }
            ([Version]) { return $this.Equals([ModuleFastSpec]::ParseVersion($obj)) }
            default {
                #Try a cast. This should work for ModuleSpecification
                try {
                    return $this.CompareTo([ModuleFastSpec]$obj)
                } catch [RuntimeException] {
                    #This is a cast error, we want to limit this so that any errors from CompareTo bubble up
                    throw "Cannot compare ModuleFastSpec to $($obj.GetType())"
                }
            }
        }
        throw [InvalidOperationException]'Unexpected Equals was found. This should never happen and is a bug in ModuleFastSpec'
    }

    #Implementation of https://learn.microsoft.com/en-us/dotnet/api/system.icomparable-1.compareto
    [int] CompareTo([Object]$obj) {
        if ($null -eq $obj) { throw [NotSupportedException]'null not supported' }

        #This is somewhat analagous to C# Pattern Matching: https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/functional/pattern-matching#compare-discrete-values
        switch ($obj.GetType()) {
            #We determine greater than or less than if the version is within the range of the spec or not
            ([SemanticVersion]) {
                if ($obj -ge $this.Min -and $obj -le $this.Max) { return 0 }
                if ($obj -lt $this.Min) { return 1 }
                if ($obj -gt $this.Max) { return -1 }
                throw 'Unexpected comparison result. This should never happen and is a bug in ModuleFastSpec'
            }
            ([ModuleFastSpec]) {
                if (-not $obj.Required) { throw [NotSupportedException]'Cannot compare two range specs as they can overlap. Supply a required spec to this range' }
                return $this.CompareTo($obj.Required) #Should go to SemanticVersion
            }
            ([Version]) {
                return $this.CompareTo([ModuleFastSpec]::ParseVersion($obj))
            }
            ([String]) {
                return $this.CompareTo([ModuleFastSpec]::ParseVersionString($obj))
            }
            default {
                if ($this.Equals($obj)) { return 0 }
                #Try a cast. This should work for ModuleSpecification
                try {
                    return $this.CompareTo([ModuleFastSpec]$obj)
                } catch [RuntimeException] {
                    #This is a cast error, we want to limit this so that any errors from CompareTo bubble up
                    throw "Cannot compare ModuleFastSpec to $($obj.GetType())"
                }
            }
        }
        throw [InvalidOperationException]'Unexpected Compare was found. This should never happen and is a bug in ModuleFastSpec'
    }

    [int] GetHashCode() {
        return $this.ToString().GetHashCode()
    }

    static [ModuleSpecification] op_Implicit([ModuleFastSpec]$moduleFastSpec) {
        $moduleSpecification = @{
            ModuleName = $moduleFastSpec.Name
        }
        if ($moduleFastSpec.Required) {
            $moduleSpecification['RequiredVersion'] = $moduleFastSpec.Required
        } else {
            #Module Specifications like nulls, so we will accomodate that.
            if ($moduleFastSpec.Min -gt [ModuleFastSpec]::MinVersion) {
                $moduleSpecification['ModuleVersion'] = [ModuleFastSpec]::ParseSemanticVersion($moduleFastSpec.Min)
            }
            if ($moduleFastSpec.Max -lt [ModuleFastSpec]::MaxVersion) {
                $moduleSpecification['MaximumVersion'] = [ModuleFastSpec]::ParseSemanticVersion($moduleFastSpec.Max)
            }
        }
        #HACK: This could be more specific but it works for this case
        if ($moduleSpecification.Keys.Count -eq 1) {
            $moduleSpecification['ModuleVersion'] = '0.0.0'
        }
        return [ModuleSpecification]$moduleSpecification
    }
}

#This is a module helper to create "getters" in classes
function Add-Getters {
    Get-Member -InputObject $this -MemberType Method -Force |
        Where-Object name -CLike 'Get_*' |
        ForEach-Object name |
        ForEach-Object {
            $getter = [ScriptBlock]::Create(('$this.{0}()' -f $PSItem))
            $property = $PSItem -replace 'Get_', ''
            Add-Member -InputObject $this -Name $property -MemberType ScriptProperty -Value $getter
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

function Get-ModuleInfoAsync {
    [CmdletBinding()]
    [OutputType([Task[String]])]
    param (
        # The name of the module to search for
        [Parameter(Mandatory, ParameterSetName = 'endpoint')][string]$Name,
        # The URI of the nuget v3 repository base, e.g. https://pwsh.gallery/index.json
        [Parameter(Mandatory, ParameterSetName = 'endpoint')]$Endpoint,
        # The path we are calling for the registration
        [Parameter(ParameterSetName = 'endpoint')][string]$Path = 'index.json',

        #The direct URI to the registration endpoint
        [Parameter(Mandatory, ParameterSetName = 'uri')][string]$Uri,

        [Parameter(Mandatory)][HttpClient]$HttpClient,
        [Parameter(Mandatory)][CancellationToken]$CancellationToken
    )

    if (-not $Uri) {
        $ModuleId = $Name

        #TODO: Call index.json and get the correct service. For now we are shortcutting this (bad behavior)
        #Strip any *.json path which might be at the end of the uri

        #HACK: We are making a *big* assumption here about the structure of the nuget repository to save an API call
        #TODO: Error handling if we are wrong by checking the main index.json manifest

        $endpointBase = $endpoint -replace '/\w+\.json$'
        $moduleInfoUriBase = "$endpointBase/registration/$ModuleId"
        $uri = "$moduleInfoUriBase/$Path"
    }

    #TODO: System.Text.JSON serialize this with fancy generic methods in 7.3?
    Write-Debug ('{0}fetch info from {1}' -f ($ModuleId ? "$ModuleId`: " : ''), $uri)
    return $HttpClient.GetStringAsync($uri, $CancellationToken)
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
        return [ModuleFastSpec]$dep
    }

    #If it is a direct module specification, treat this as a required version.
    $exactVersion = $null
    if ([Version]::TryParse($Version, [ref]$exactVersion)) {
        $dep.RequiredVersion = $exactVersion
        return [ModuleFastSpec]$dep
    }

    #If it is an open bound, set ModuleVersion to 0.0.0 (meaning any version)
    if ($version -eq '(, )') {
        $dep.ModuleVersion = '0.0.0'
        return [ModuleFastSpec]$dep
    }

    #If it is an exact match version (has brackets and doesn't have a comma), set version accordingly
    $ExactVersionRegex = '\[([^,]+)\]'
    if ($version -match $ExactVersionRegex) {
        $dep.RequiredVersion = $matches[1]
        return [ModuleFastSpec]$dep
    }

    #Parse all other remainder options. For this purpose we ignore inclusive vs. exclusive
    #TODO: Add inclusive/exclusive parsing
    $version = $version -replace '[\[\(\)\]]', '' -split ','

    $minimumVersion = $version[0].trim()
    $maximumVersion = $version[1].trim()
    if ($minimumVersion -and $maximumVersion -and ($minimumVersion -eq $maximumVersion)) {
        #If the minimum and maximum versions match, we treat this as an explicit version
        $dep.RequiredVersion = $minimumVersion
        return [ModuleFastSpec]$dep
    } elseif ($minimumVersion -or $maximumVersion) {
        if ($minimumVersion) { $dep.ModuleVersion = $minimumVersion }
        if ($maximumVersion) { $dep.MaximumVersion = $maximumVersion }
    } else {
        #If no matching version works, just set dep to a string of the modulename
        Write-Warning "$($dep.ModuleName) has an invalid version spec, falling back to maximum version."
    }

    return [ModuleFastSpec]$dep
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
        [Parameter(Mandatory)][ModuleFastSpec]$ModuleSpec,
        [string[]]$ModulePath = $($env:PSModulePath -split [Path]::PathSeparator)
    )
    $ErrorActionPreference = 'Stop'
    # BUG: Prerelease Module paths are still not recognized by internal PS commands and can break things

    # Search all psmodulepaths for the module
    $modulePaths = $env:PSModulePath -split [Path]::PathSeparator

    # NOTE: We are intentionally using return instead of continue here, as soon as we find a match we are done.
    foreach ($modulePath in $modulePaths) {
        if ($moduleSpec.Required) {
            #We can speed up the search for explicit requiredVersion matches
            #HACK: We assume a release version can satisfy a prerelease version constraint here.
            $manifestPath = Join-Path $modulePath $ModuleSpec.Name $($ModuleSpec.Required) "$($ModuleSpec.Name).psd1"
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
            $versionMatch = Limit-ModuleFastSpecVersions -ModuleSpec $ModuleSpec -Versions $candidateVersions -Highest
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

# Find all normalized versions of a version, for example 1.0.1.0 also is 1.0.1
function Get-NormalizedVersions ([Version]$Version) {
    $versions = @()
    if ($Version.Revision -eq 0) { $versions += [Version]::new($Version.Major, $Version.Minor, $Version.Build) }
    if ($Version.Build -eq 0) { $versions += [Version]::new($Version.Major, $Version.Minor) }
    if ($Version.Minor -ne 0) { $versions += [Version]::new($Version.Major) }
    return $versions
}

<#
Given an array of versions, find the ones that satisfy the module spec. Returns $false if no match is found.
#>
function Limit-ModuleFastSpecVersions {
    [OutputType([Version[]])]
    [OutputType([Version], ParameterSetName = 'Highest')]
    param(
        [Parameter(Mandatory)][ModuleFastSpec]$ModuleSpec,
        #Versions that are potential candidates to satisfy the modulespec
        [Parameter(Mandatory)][HashSet[Version]]$Versions,
        #Only return the highest version that satisfies the spec
        [Parameter(ParameterSetName = 'Highest')][Switch]$Highest
    )
    $candidates = $Versions | Where-Object {
        $ModuleSpec.Matches($PSItem)
    }
    -not $Highest ? $candidates : $candidates | Sort-Object -Descending | Select-Object -First 1
}

function Limit-ModuleFastSpecSemanticVersions {
    [OutputType([SemanticVersion[]])]
    [OutputType([Version], ParameterSetName = 'Highest')]
    param(
        [Parameter(Mandatory)][ModuleFastSpec]$ModuleSpec,
        #Versions that are potential candidates to satisfy the modulespec
        [Parameter(Mandatory)][HashSet[SemanticVersion]]$Versions,
        #Only return the highest version that satisfies the spec
        [Parameter(ParameterSetName = 'Highest')][Switch]$Highest
    )
    $Versions | Where-Object {
        $ModuleSpec.Matches($PSItem)
    }
    -not $Highest ? $Versions : @($Versions | Sort-Object -Descending | Select-Object -First 1)
}
function Limit-ModuleFastSpecs {
    [OutputType([ModuleFastSpec[]])]
    [OutputType([Version], ParameterSetName = 'Highest')]
    param(
        [Parameter(Mandatory)][ModuleFastSpec]$ModuleSpec,
        #Versions that are potential candidates to satisfy the modulespec
        [Parameter(Mandatory)][HashSet[ModuleFastSpec]]$ModuleSpecs,
        #Only return the highest version that satisfies the spec
        [Parameter(ParameterSetName = 'Highest')][Switch]$Highest
    )
    $ModuleSpecs | Where-Object {
        $ModuleSpec.Matches($PSItem)
    }
    -not $Highest ? $Versions : @($Versions | Sort-Object -Descending | Select-Object -First 1)
}

#endregion Helpers

# Export-ModuleMember Get-ModuleFast


### ISSUES
# FIXME: When doing directory match comparison for local modules, need to preserve original folder name. See: Reflection 4.8
#   To fix this we will just use the name out of the module.psd1 when installing
# FIXME: DBops dependency version issue
# FIXME: Currently Legacy 1.2.3 will be selected over 1.2.3.1111 due to semver versioning sort order, need additional logic if build is present. This can be implemented in CompareTo based on the build tag.
# FIXME IN GALLERY: A version not in the latest 100 versions will not be found, we are checking for a NextLink but this needs to be wired up to a page request.

# Export-ModuleMember -Function Get-ModuleFastPlan