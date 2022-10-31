# ModuleFast

This is a PowerShell module installer that is optimized for high performance and no external dependencies so it can be
used as a bootstrap.

## How this script works

1. Takes your module specifications and builds a declarative dependency tree, following a IaC plan/apply approach to installing modules.
1. Uses a custom HTTPClient and async tasks to build the dependency tree quickly, querying with minimal data possible and
   using batch queries where possible to optimize for performance. This is all done in native PowerShell, no C# required
   (though C# would allow for certain operations to be even more parallelizable by chaining tasks).
1. Uses HTTP/2 to speed up queries where available (PSGallery supports it)

## What this script is not

This is an example of how fast things *can* be, with certain assumptions, but it only works against a single NuGet v2
repository at the moment and is pretty much only tested with PowerShell Gallery. It is *not* a replacement for
PowerShellGet, which has much broader support for multiple repos, authentication, etc.

It makes a lot of very bad assumptions, most of which are safe for PowerShell Gallery at least

1. Nuget v2 Only
1. Powershell 7+ Only
1. OData Raw API (vs NuGet functions) is available, which has been deprecated. We use these because they are faster and more documented.
1. Batch API is available
1. PowerShellGet is built for compatibility with PSGetv2, I have no such compatibility restrictions and can build "from scratch"
1. It currently has very little error handling and aggressive timeouts, and not recommended for slow or unreliable
   network connections. It will "fail fast" as much as possible.
1. Dependency resolution only takes into account the modules in the direct target folder. For example, if modules are
installed in local computer that would satisfy the dependency graph, they'll be installed into user module folder anyways
and vice versa.

## Dependency Resolution

This module uses a custom dependency resolution algorithm that selects the newest available modules that satisfy all the
dependency criteria. If a version of a locally installed module satisfies the "latest" criteria of the dependency graph,
it will be used rather than fetching what is newest on the gallery.

`Update-ModuleFast` will only update the explicitly requested modules, but downstream dependencies will not be updated
unless `-All` is specified.
