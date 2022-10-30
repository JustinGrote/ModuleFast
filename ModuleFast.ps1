#requires -version 5
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
It also handles dependencies (via Nuget), checks for existing packages, and caches already downloaded packages
.NOTES
THIS IS NOT FOR PRODUCTION, it should be considered "Fragile" and has very little error handling and type safety
It also doesn't generate the PowershellGet XML files currently, so PowershellGet will see them as "External" modules
#>

# if (-not (Get-Command 'nuget.exe')) {throw "This module requires nuget.exe to be in your path. Please install it."}


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
        return ($this.Name, $this.Guid, $this.Version, $this.MaximumVersion, $this.RequiredVersion -join ':').GetHashCode()
    }
    [bool] Equals($obj) {
        return $this.GetHashCode().Equals($obj.GetHashCode())
    }
}

function Get-ModuleFast {
    [CmdletBinding()]
    param(
        #A list of modules to install, specified either as strings or as hashtables with nuget version style (e.g. @{Name='test';Version='1.0'})
        [Parameter(ValueFromPipeline)][Object]$Name,
        #Whether to include prerelease modules in the request
        [Switch]$PreRelease,
        $Source = 'https://www.powershellgallery.com/api/v2/Packages'
    )

    BEGIN {
        $ErrorActionPreference = 'Stop'
        [HashSet[ComparableModuleSpecification]]$modulesToResolve = @()

        #Only need one httpclient for all operations
        if (-not $httpclient) {
            #This is the modern default handler for HttpClient. We want more concurrent connections to improve our performance and fairly aggressive timeouts
            $httpHandler = [SocketsHttpHandler]@{
                MaxConnectionsPerServer = 10
                ConnectTimeout          = 1000
            }
            $SCRIPT:httpClient = [HttpClient]::new($httpHandler)
            $httpClient.BaseAddress = 'https://www.powershellgallery.com/api/v2'
            $httpClient.DefaultRequestHeaders = @{
                'Content-Type' = 'multipart/mixed; boundary=GetModuleFastBatch'
            }
        }
        Write-Progress -Id 1 -Activity 'Get-ModuleFast' -CurrentOperation 'Fetching module information from Powershell Gallery'
    }
    PROCESS {
        foreach ($spec in $Name) {
            if (-not $ModulesToResolve.Add($spec)) {
                Write-Warning "$spec was specified twice, skipping duplicate"
            }
        }
    }
    END {
        [List[Task[String]]]$resolveTasks = @()
        [ConcurrentDictionary[String, ComparableModuleSpecification]]$modulesToInstall = @{}


        foreach ($moduleToResolve in $modulesToResolve) {
            $resolveTask = Get-PSGalleryModuleInfoAsync $moduleToResolve
            $resolveTasks.Add($resolveTask)
        }

        while ($resolveTasks) {
            [int]$thisTaskIndex = [Task]::WaitAny($resolveTasks)
            $completedTask = $resolveTasks[$thisTaskIndex]
            #Doing this provides a proper exception if there is an error rather than aggregate exception
            #TODO: TryCatch logic for GetResult
            [string]$moduleData = $completedTask.result
            $moduleItem = ([xml]$moduleData).feed.entry
            #TODO: Consolidate this
            [string[]]$Properties = [string[]]('Id', 'Version', 'NormalizedVersion')
            $OutputProperties = $Properties + @{N = 'Source'; E = { $ModuleItem.content.src } } + @{N = 'Dependencies'; E = { $_.Dependencies.split(':|').TrimEnd(':') } }
            $moduleInfo = $ModuleItem.properties | Select-Object $OutputProperties

            #Create a module spec with our returned info
            [ComparableModuleSpecification]$moduleSpec = @{
                ModuleName      = $moduleInfo.Id
                RequiredVersion = $moduleInfo.Version
            }
            #Create a key to uniquely identify this moduleSpec so we dont do duplicate queries
            [string]$moduleKey = $moduleSpec.Name, $moduleSpec.RequiredVersion -join '-'

            #Check if we have already processed this item and move on if we have
            if ($modulesToInstall.ContainsKey($moduleKey)) {
                Write-Debug "$ModuleKey ModulesToInstall already exists. Skipping..."
                $resolveTasks.RemoveAt($thisTaskIndex)
                Write-Debug "Remaining Tasks: $($resolveTasks.count)"
                continue
            }

            Write-Debug "$ModuleKey Adding to ModulesToInstall. "

            $modulesToInstall[$moduleKey] = $moduleSpec

            #Determine dependencies and add them to the pending tasks
            if ($moduleInfo.Dependencies) {
                [List[ComparableModuleSpecification]]$dependencies = $moduleInfo.Dependencies | Parse-NugetDependency
                Write-Debug "$($moduleSpec.Name) has $($dependencies.count) dependencies"
                foreach ($dependency in $dependencies) {
                    #Create a key to uniquely identify this moduleSpec so we dont do duplicate queries
                    [string]$dependencyKey = $dependency.Name, $dependency.RequiredVersion -join '-'

                    #Check if we have already processed this item and move on if we have
                    if ($modulesToInstall.ContainsKey($dependencyKey)) {
                        Write-Debug "$ModuleKey dependency - ModulesToInstall already exists. Skipping..."
                        Write-Debug "Remaining Tasks: $($resolveTasks.count)"
                        continue
                    }

                    #Check
                    #TODO: Lookup instead of enumerable, should be fast enough for now

                    Write-Debug "Start lookup for $ModuleKey"
                    $resolveTask = Get-PSGalleryModuleInfoAsync $dependency
                    $resolveTasks.Add($resolveTask)
                }
            }

            $resolveTasks.RemoveAt($thisTaskIndex)
            Write-Debug "Remaining Tasks: $($resolveTasks.count)"
        }
        Write-Debug "Finished processing ${$moduleToResolve.Name}"
        if (-not $modulesToResolve.Remove($moduleToResolve)) {
            throw 'There was an error removing a moduleToResolve. This should not happen'
        }
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
        [Parameter(Mandatory, ValueFromPipeline)][Microsoft.PowerShell.Commands.ModuleSpecification]$Name,
        [string[]]$Properties = [string[]]('Id', 'Version', 'NormalizedVersion', 'Dependencies'),
        [string]$Uri = 'https://www.powershellgallery.com/api/v2/Packages',
        [HttpClient]$HttpClient = [HttpClient]::new(),
        [Switch]$PreRelease
    )

    process {
        [uribuilder]$galleryQuery = $Uri
        #Creates a Query Name Value Builder
        $queryBuilder = [web.httputility]::ParseQueryString($null)
        $ModuleId = $Name.Name

        $FilterSet = @()
        $FilterSet += "Id eq '$ModuleId'"
        $FilterSet += "IsPrerelease eq $(([String]$PreRelease).ToLower())"
        switch ($true) {
            ([bool]$Name.RequiredVersion) {
                $FilterSet += "Version eq '$($Name.RequiredVersion)'"
                #RequiredVersion is exact, so we dont need to check other version fields
                break
            }
            ([bool]$Name.Version) {
                $FilterSet += "Version ge '$($Name.Version)'"
            }
            #We assume for now that if you set the max as "2.0" you really meant "1.99"
            #TODO: Fix this to handle explicit/implicit dependencies
            ([bool]$Name.MaximumVersion) {
                $FilterSet += "Version lt '$($Name.MaximumVersion)'"
            }
        }
        #Construct the Odata Query
        $Filter = $FilterSet -join ' and '
        [void]$queryBuilder.Add('$top', '1')
        [void]$queryBuilder.Add('$filter', $Filter)
        [void]$queryBuilder.Add('$orderby', 'Version desc')
        [void]$queryBuilder.Add('$select', ($Properties -join ','))

        # ToString is important here
        $galleryQuery.Query = $queryBuilder.ToString()
        Write-Debug $galleryquery.uri
        return $httpClient.GetStringAsync($galleryQuery.Uri)
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

        [ByteArrayContent]$httpRequest = [Encoding]::UTF8.GetBytes("GET $content HTTP/1.1")
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
    if (-not $batchSeparator) { throw 'Invalid Response from API, no batch separator header found' }

    $responseData = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    [List[string]]$splitResponse = $responseData.Split("--$batchSeparator")
    #PSGallery adds an additional "--" to the last batch response header, we need to clean this up if present
    #This method is faster than doing where-object because we dont have to enumerate the response and evaluate each entry
    if ($splitResponse[-1].Trim() -eq '--') { $splitResponse.RemoveAt(($splitResponse.Count - 1)) }

    return $splitResponse
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