#requires -version 7
using namespace System.Text
using namespace System.Net.Http
using namespace System.Threading.Tasks
using namespace System.Collections.Generic
using namespace System.Collections.Concurrent
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
    [CmdletBinding()]
    param(
        #A list of modules to install, specified either as strings or as hashtables with nuget version style (e.g. @{Name='test';Version='1.0'})
        [Parameter(Mandatory, ValueFromPipeline)][Object]$Name,
        #Whether to include prerelease modules in the request
        [Switch]$PreRelease,
        $Source = 'https://www.powershellgallery.com/api/v2/Packages',
        #By default, every request is made individually as batch requests are processed serially. You may hit an API
        #throttling limit due to this behavior, so you can set this value to how many concurrent connections you wish to do.
        [int]$MaxBatchConnections = -1
    )

    BEGIN {
        $ErrorActionPreference = 'Stop'
        [HashSet[ComparableModuleSpecification]]$modulesToResolve = @()

        if (-not $httpclient) {
            #SocketsHttpHandler is the modern .NET 5+ default handler for HttpClient.
            #We want more concurrent connections to improve our performance and fairly aggressive timeouts
            #The max connections are only in case we end up using HTTP/1.1 instead of HTTP/2 for whatever reason.
            $httpHandler = [SocketsHttpHandler]@{
                MaxConnectionsPerServer = 100
                # ConnectTimeout          = 1000
            }
            #Only need one httpclient for all operations, hence why we set it at Script (Module) scope
            $SCRIPT:httpClient = [HttpClient]::new($httpHandler)
            $httpClient.BaseAddress = 'https://www.powershellgallery.com/api/v2'
            $httpClient.DefaultRequestHeaders.UserAgent.TryParseAdd('ModuleFast (https://gist.github.com/JustinGrote/ecdf96b4179da43fb017dccbd1cc56f6)')
            #Default to HTTP/2. This will multiplex all queries over a single connection, minimizing TLS setup overhead
            $httpClient.DefaultRequestVersion = '2.0'
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

        #TODO: We are aggressive and assume the endpoint is a NuGet v2 endpoint.
        #There should be logic that, if this request fails, do a test at the root endpoint and give the user
        #A more friendly error that they probably are not pointing at a proper NuGet v2 repository.
        [List[Task[HttpResponseMessage]]]$resolveTasks = $modulesToResolve | Get-PSGalleryModuleInfoAsync -HttpClient $httpclient

        while ($resolveTasks) {
            #The timeout here allow ctrl-C to continue working in PowerShell
            $noTasksYetCompleted = -1

            [int]$thisTaskIndex = [Task]::WaitAny($resolveTasks, 500)
            if ($thisTaskIndex -eq $noTasksYetCompleted) { continue }

            #TODO: This only indicates headers were received, content may still be downloading and we dont want to block on that.
            #For now the content is small but this could be faster if we have another inner loop that WaitOne's on content
            $completedTask = $resolveTasks[$thisTaskIndex]

            # We use GetAwaiter so we get proper error messages back, as things such as network errors might occur here.
            #TODO: TryCatch logic for GetResult
            $rawResponse = $completedTask.GetAwaiter().GetResult()

            #TODO: Error handling for unknown data types
            [string[]]$responseBody = if ($rawResponse.Content.Headers.ContentType.MediaType -eq 'multipart/mixed') {
                $response = $rawResponse | ConvertFrom-MultiPartResponse

                #HACK: We get back headers with this multipart response too. I can't find a good built-in method to parse
                # this into an HttpResponse so we are going to make a *BIG* assumption that the body is the third "paragraph"
                # after the Headers. This might not work cross-platform either.
                #TODO: Find a more accurate and safe way of parsing this
                foreach ($responseItem in $response) {
                    $responseItem.split([Environment]::NewLine * 2)[2]
                }
            } else {
                $rawResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }

            #TODO: This should be a separate function with a pipeline
            foreach ($moduleData in $responseBody) {
                $moduleItem = ([xml]$moduleData).feed.entry
                #TODO: Consolidate this
                [string[]]$Properties = [string[]]('Id', 'NormalizedVersion', 'GUID')
                $OutputProperties = $Properties + @{N = 'Source'; E = { $ModuleItem.content.src } } + @{N = 'Dependencies'; E = { $_.Dependencies.split(':|').TrimEnd(':') } }
                $moduleInfo = $ModuleItem.properties | Select-Object $OutputProperties

                #Create a module spec with our returned info
                [ComparableModuleSpecification]$moduleSpec = @{
                    ModuleName      = $moduleInfo.Id
                    RequiredVersion = $moduleInfo.NormalizedVersion
                    GUID            = $moduleInfo.Guid
                }

                #Check if we have already processed this item and move on if we have
                if (-not $modulesToInstall.Add($moduleSpec)) {
                    Write-Debug "$ModuleSpec ModulesToInstall already exists. Skipping..."
                    continue
                }

                Write-Debug "$moduleSpec Added to ModulesToInstall. "

                #Determine dependencies and add them to the pending tasks
                if ($moduleInfo.Dependencies) {
                    [List[ComparableModuleSpecification]]$dependencies = $moduleInfo.Dependencies | Parse-NugetDependency
                    Write-Debug "$moduleSpec has $($dependencies.count) dependencies"

                    # TODO: Where loop filter maybe
                    [ComparableModuleSpecification[]]$dependenciesToResolve = $dependencies | Where-Object {
                        # TODO: This dependency resolution logic should be a separate function
                        # Maybe ModulesToInstall should be nested/grouped by Module Name then version to speed this up, as it currently
                        # enumerates every time which shouldn't be a big deal for small dependency trees but might be a
                        # meaninful performance difference on a whole-system upgrade.
                        [HashSet[string]]$moduleNames = $modulesToInstall.Name
                        if ($PSItem.Name -notin $ModuleNames) {
                            Write-Debug "$PSItem not in ModulesToInstall. Performing lookup."
                            return $true
                        }

                        $plannedVersions = $modulesToInstall
                        | Where-Object Name -EQ $PSItem.Name
                        | Sort-Object RequiredVersion -Descending

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
                            Write-Debug "$($PSItem.Name): Explicity Required Version $($PSItem.Required) is not within existing planned versions ($($plannedVersions.RequiredVersion -join ',')). Performing Lookup"
                            return $true
                        }

                        #If it didn't match, skip it
                        Write-Debug "$($PSItem.Name) dependency satisfied by $highestPlannedVersion already in the plan"
                    }

                    Write-Debug "Fetching info on remaining $($dependencies.count) dependencies"

                    #This will chunk requests into batches if requested.
                    #By default individual requests are still made for max performance
                    if ($maxBatchConnections -le 0) {
                        foreach ($dependency in $dependenciesToResolve) {
                            $resolveTasks.Add((Get-PSGalleryModuleInfoAsync -HttpClient $httpclient -Name $dependency))
                        }
                    } else {
                        [int]$batchSize = ($dependenciesToResolve.count / $MaxBatchConnections ) + 1

                        $i = 0
                        do {
                            $resolveTask = $dependenciesToResolve[$i..($i + $batchSize)] | Get-PSGalleryModuleInfoAsync -HttpClient $httpclient
                            $resolveTasks.Add($resolveTask)
                            $i += $batchSize + 1
                        } until (
                            $i -ge $dependenciesToResolve.count
                        )
                    }
                }
            }
            try {
                $resolveTasks.RemoveAt($thisTaskIndex)
            } catch {
                Wait-Debugger
            }
            Write-Debug "Remaining Tasks: $($resolveTasks.count)"
        }

        return $modulesToInstall
    }

    #TODO: Port this logic
    #Loop through dependencies to the expected depth
    #     $currentDependencies = @($modulesToInstall.dependencies.where{ $PSItem })
    #     $i = 0

    #     while ($currentDependencies -and ($i -le $depth)) {
    #         Write-Verbose "$($currentDependencies.count) modules had additional dependencies, fetching..."
    #         $i++
    #         $dependencyName = $CurrentDependencies -split '\|' | ForEach-Object {
    #             Parse-NugetDependency $PSItem
    #         } | Sort-Object -Unique
    #         if ($dependencyName) {
    #             $dependentModules = Get-PSGalleryModule $dependencyName
    #             $modulesToInstall += $dependentModules
    #             $currentDependencies = $dependentModules.dependencies.where{ $PSItem }
    #         } else {
    #             $currentDependencies = $false
    #         }
    #     }
    #     $modulesToInstall = $modulesToInstall | Sort-Object id, version -Unique
    #     return $modulesToInstall
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
        [Switch]$Force
    )

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

function Get-NotInstalledModules ([String[]]$Name) {
    $InstalledModules = Get-Module $Name -ListAvailable
    $Name.where{
        $isInstalled = $PSItem -notin $InstalledModules.Name
        if ($isInstalled) { Write-Verbose "$PSItem is already installed. Skipping..." }
        return $isInstalled
    }
}

function Get-PSGalleryModuleInfoAsync {
    [CmdletBinding()]
    [OutputType([Task[string]])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)][ComparableModuleSpecification]$Name,
        [string[]]$Properties = [string[]]('Id', 'NormalizedVersion', 'Dependencies', 'GUID'),
        [string]$Uri = 'https://www.powershellgallery.com/api/v2/',
        [Parameter(Mandatory)][HttpClient]$HttpClient,
        [Switch]$PreRelease
    )
    begin {
        #If we are given duplicate queries, we will deduplicate them to avoid unnecessary traffic.
        [HashSet[string]]$queries = @()
    }

    process {
        $moduleSpec = $Name
        $ModuleId = $ModuleSpec.Name

        [uribuilder]$galleryQuery = $Uri

        #Creates a Query Name Value Builder
        $queryBuilder = [web.httputility]::ParseQueryString($null)
        [void]$queryBuilder.Add('$select', ($Properties -join ','))
        $FilterSet = @()

        # If this is a RequiredVersion query, we can request the item directly
        if ($ModuleSpec.RequiredVersion) {
            $galleryQuery.Path += "Packages(Id='{0}',Version='{1}')" -f $moduleId, $ModuleSpec.RequiredVersion
        } else {
            $galleryQuery.Path += 'FindPackagesById()'
            [void]$queryBuilder.Add('id', "'$ModuleId'")
            [void]$queryBuilder.Add('semVerLevel', '2.0.0')
            if ($Prerelease) { $filterSet += 'IsPrerelease eq true' }

            # If no "upper" constraints are set, we can safely use the isLatestVersion query to minimize data result
            if (-not $ModuleSpec.MaximumVersion) {
                $FilterSet = $Prerelease ? 'IsAbsoluteLatestVersion eq true' : 'IsLatestVersion eq true'
            }

            # For all other queries, we need to filter the results client-side because odata filters are lexical
            # and a version like 2.10 will show as less than 2.2
            #FIXME: Need to preserve state with a dictionary of the comparablemodulespec request and the http request
            #So we can correlate the results
        }

        #Construct the Odata Query
        if ($FilterSet) {
            $Filter = $FilterSet -join ' and '
            [void]$queryBuilder.Add('$filter', $Filter)
        }

        # ToString is important here
        $galleryQuery.Query = $queryBuilder.ToString()
        Write-Debug $galleryquery.uri
        [void]$queries.Add($galleryQuery.Uri)
    }
    end {
        if (-not $queries) { throw 'No queries were found. This is a bug.' }
        if ($queries.Count -eq 1) {
            return $httpClient.GetAsync($queries[0])
        }
        #Build a batch query from our string queries
        $request = $queries | New-MultipartGetQuery

        #Will return a task to await the response
        #TODO: Saner batch attachment
        return $httpClient.PostAsync($($Uri + '$batch'), $request)
    }
}

filter Parse-NugetDependency ([Parameter(ValueFromPipeline)][String]$DependencyString) {
    #NOTE: RequiredVersion is used for Minimumversion and ModuleVersion is RequiredVersion for purposes of Nuget query
    $DependencyParts = $DependencyString -split '\:'

    #NOTE: This can't be a modulespecification from the start because modulespecs are immutable
    $dep = @{
        ModuleName = $DependencyParts[0]
    }
    $Version = $DependencyParts[1]

    if ($Version) {
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
            Write-Warning "$($dep.Name) has an invalid version spec, falling back to maximum version."
        }
    }

    return [ComparableModuleSpecification]$dep
}


<#
.SYNOPSIS
Builds a multipart query from a list of strings that represent HTTP GET Queries
#>
function New-MultipartGetQuery {
    [OutputType([StringContent])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)][string]$content,
        [string]$boundary = "powershell-$(New-Guid)",
        [MultiPartContent]$request
    )

    begin {
        if (-not $request) {
            $request = [MultipartContent]::new('mixed', $boundary)
        }
    }

    process {
        # HttpContentMessage is part of ASP.NET, not HttpClient, so we have to roll our own

        #Using Stringcontent and changing the headers is easier than using ByteArrayContent
        #An extra newline separator is required by PowerShell Gallery for some reason.
        [StringContent]$httpRequest = "GET $content HTTP/1.1" + [Environment]::NewLine
        $httpRequest.Headers.ContentType = 'application/http'
        $httpRequest.Headers.Add('Content-Transfer-Encoding', 'binary')
        $request.Add($httpRequest)
    }

    end {
        # BUG: MultiPartContent adds an additional batch separator line at the end, and Powershell Gallery does not like
        # this and throws a 406 not acceptable, so we must trim this off.
        # I couldn't find a way to do this in the multipart
        # class directly so we instead make a new stringcontent from the multipart and trim manually.
        # TODO: Maybe have a requestmessagehandler that can do it?
        [string]$requestBody = $request.ReadAsStringAsync().GetAwaiter().GetResult()
        # Strip the last boundary line
        [StringContent]$fixedRequest = $requestBody.TrimEnd().Remove($requestBody.LastIndexOf("--$boundary"))
        $fixedRequest.Headers.ContentType = $request.Headers.ContentType

        # PowerShell wants to unwrap MultiPartContent since it is an ienumerable, the "," adds an "outer array" so that
        # multipart content comes through correctly.
        return $fixedRequest
    }
}

<#
.SYNOPSIS
Takes a multipart response received from the API and breaks it into a string array based on the separators
#>
filter ConvertFrom-MultiPartResponse ([Parameter(ValueFromPipeline)][HttpResponseMessage]$response) {
    [string]$batchSeparator = ($response.Content.Headers.ContentType.Parameters | Where-Object Name -EQ 'boundary').Value
    if (-not $batchSeparator) { throw 'Invalid Response from API, no batch separator header found. This should not happen and is probably a bug.' }

    # This might be slow because we might be waiting on data to receive while other data might be ready to go.
    #TODO: Move this processing up to the main operation and this function should take two parameters for the string
    #response and the boundary
    $responseData = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    #I can't find a good method to convert the string representation of an HTTP response into an object, so we will make
    #A BIG assumption here that the headers have two separate newlines. This will probably be the source of a lot of
    #Non-PSGallery Bugs
    [List[string]]$splitResponse = $responseData.Split("--$batchSeparator")
    #PSGallery adds an additional "--" to the last batch response header, we need to clean this up if present
    #This method is faster than doing where-object because we dont have to enumerate the response and evaluate each entry
    if ($splitResponse[-1].Trim() -eq '--') { $splitResponse.RemoveAt(($splitResponse.Count - 1)) }

    #The Where-Object filters out blank entries.
    #TODO: Faster way maybe?
    return $splitResponse | Where-Object { $PSItem }
}

# Takes a group of queries and converts them to a single odata batch request body used for httpclient
# filter ConvertTo-BatchRequest([Parameter(Mandatory,ValueFromPipeline)][string]$query, [string]$batchBoundary='GetModuleFastBatch') {
#     begin {
#         [text.StringBuilder]$body = @'
# ---batch
#         '@
#     }

#     $body.AppendLine(

#     )
# }

# Create a http multipart query


#Multipart stuff


#endregion Helpers

# Export-ModuleMember Get-ModuleFast
