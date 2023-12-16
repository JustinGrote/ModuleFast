![ModuleFast Logo](./images/logo.gif)
# ModuleFast

This is a PowerShell module installer that is optimized for high performance and no external dependencies so it can be
used as a bootstrap to quickly install and update modules in a declarative fashion.

## Quick Start Bootstrap

### Load ModuleFast as a module for the session

ModuleFast can be quickly bootstrapped without relying on the built-in PowershellGet package manager

```powershell
iwr bit.ly/modulefast | iex
Install-ModuleFast ImportExcel
```

The bit.ly link will always point to the latest release of ModuleFast by default. In order to avoid breaking changes, you can pin to a specific release. This is recommended when using CI systems such as GitHub Actions to install dependencies but is generally not needed on an interactive basis.

### Single Line Installation (good for CI/CD)

Adding args to the bootstrap passes them to Install-ModuleFast automatically, so you can one-line install modules as needed.
This passes thru all arguments to ModuleFast.

```powershell
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) ImportExcel
```

The bit.ly link will always point to the latest release of ModuleFast by default. In order to avoid breaking changes, you can pin to a specific release. This is recommended when using CI systems such as GitHub Actions to install dependencies but is generally not needed on an interactive basis.

```powershell
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) -Release '1.0' ImportExcel
```

### ModuleSpecification Install

You can specify a set of `ModuleSpecification` hashtables to Install-ModuleFast for explicit version constraints. For instance,
you can have only a very specific version to be installed, or only versions below a certain to be installed as well.

```powershell
#Installs the latest ImportExcel lower than 7.7.0
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) @{ModuleName='ImportExcel';MaximumVersion='7.7.0'}
```

### NOTE: Recommended PSModulePath Prerequisite

ModuleFast installs modules to your `LocalAppData/powershell/Modules` folder.
This is the default install folder on Linux however it is not on Windows, so on Windows the
script will automatically update your profile to add this path to your psmodulepath on startup (it will prompt you to do this).
You can alternatively set it as your `powershell.config.json` PSModulePath, add it to your PSModulePath another way such as in your profile, or specify -Destination to point wherever you want, such as the classic "Documents" location.

## Goals

* Given a set of packages, install the packages and their dependencies as fast as possible in a declarative plan/apply incremental approach.
* Packages once deployed should be fully compatible with built-in *-Module commands, PSGetv2, and PSGetv3.
* Support a "plan" view that shows what will change before it changes, Terraform-style
* Support a dependencies file that can declaratively define what packages a module should have
* Support a "complete" mode that will clean up packages that aren't the latest versions of the specified modules.

## Non-Goals

* **This is not a replacement for PowerShellGetv3** This is a compliment to the hard work being done there. The focus with
PSGetv3 is compatibility, the focus with ModuleFast is speed of installation/update at the expense of backwards compatability.
* It will probably never support nuget v2 repositories, only nuget v3. PowerShell Gallery is supported via `pwsh.gallery`, a nuget v2 -> v3 proxy (though any nuget v2 repo could be supported in this fashion)
* It will likely not support local filesystem or fileshares for installation, since those are usually fast enough with PSGet/PSResourceGet. I may add them for more unified dependency resolution.

## How this script works

1. Takes your module specifications and builds a declarative dependency tree, following a IaC plan/apply approach to installing modules. By default it will evaluate locally installed modules in all of your configured PSModulePath to determine if an already-installed module meets the criteria.
1. Uses a custom HTTPClient and async tasks to build the dependency tree quickly, querying with minimal data possible and using batch queries where possible to optimize for performance. This is all done in native PowerShell, no C# required (though C# would allow for certain operations to be even more parallelizable by chaining tasks).
1. Uses HTTP/2 to run all queries in a single TCP conversation where possible (PSGallery supports it)
1. For PowerShell Gallery, uses an optimized [CloudFlare Worker](https://github.com/justingrote/pwshgallery) to resolve dependencies as fast as possible.

## What this script is not

This is an example of how fast things *can* be, with certain assumptions. It is *not* a replacement for
PowerShellGet, which has much broader support for multiple repos, authentication, etc.

It makes a lot of very bad assumptions, most of which are safe for PowerShell Gallery at least

1. Nuget v3 Only. PowerShellGet is built for compatibility with PSGetv2, I have no such compatibility restrictions and can build "from scratch"
1. Powershell 7+ Only. PowerShellGet has 5.1+ compatibility
1. Modules with a particular GUID and version are immutable and never change. This is great for caching purposes, and is true for PSGallery, but may not be true for other galleries.
1. It currently has very little error handling and aggressive timeouts, and not recommended for slow or unreliable
   network connections. It will "fail fast" as much as possible.

## Lessons learned

1. Multipart $batch queries suck, they still only execute server-side in parallel. I wrote a full multipart implementation only to throw it away
1. Fiddler and some proxies only supports HTTP/1.1 and can give false positives about how many connections are actually being made. Use wireshark to be sure when testing HTTP/2 and HTTP/3
1. [Dictionary].keys is not a stable target at all for task iteration, best to maintain a separate list
1. PSGetv3 doesn't follow the nuget server v3 spec of optional params (stuff marked optional will cause psgetv3 to throw if not present)
1. Initially the logic would fetch the main page and resolve dependencies by fetching individual versions. Turns out its only barely slower to return all versions of a module in single call, probably because the PSGallery server-side filtering doesnt cache, so we instead fetch all versions of a module in a reduced way from our Cloudflare worker and use that as a cache.
1. Parallel dependency lookups (lots of Az dependencies require Az.Account) resulted in lots of duplicate calls for Az.Account. Since all task calls bottleneck through our main async loop logic, we can safely inspect existing dependency calls just before execution to determine if the existing call will satisfy it, and then add the context on to the existing object to prevent the duplicate calls.

## Dependency Resolution

This module uses a custom dependency resolution algorithm that selects the newest available modules that satisfy all the
dependency criteria. If a version of a locally installed module satisfies the "latest" criteria of the dependency graph,
it will be used rather than fetching what is newest on the gallery. This can be overriden with the `-Update` switch that
will recheck whats available in the remote.

### Testing Latest Master

```powershell
function Test-ModuleFast {
  $mfbootstrap = [ScriptBlock]::Create((iwr 'https://raw.githubusercontent.com/JustinGrote/ModuleFast/main/ModuleFast.ps1').content)
  $mfpsm1 = 'https://raw.githubusercontent.com/JustinGrote/ModuleFast/main/ModuleFast.psm1'
  $mfbootstrap -Uri $mfpsm1
}
$PSDefaultParameterValues['*-ModuleFast:Source'] = 'https://preview.pwsh.gallery/index.json'
Test-ModuleFast
```
