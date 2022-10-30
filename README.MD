# ModuleFast

This is a PowerShell module installer that is optimized for high performance and no external dependencies so it can be
used as a bootstrap.

## How this script works

1. Takes your module specifications and builds a declarative dependency tree, following a IaC plan/apply approach to installing modules.
1. Uses a custom HTTPClient and async tasks to build the dependency tree quickly, querying with minimal data possible and
   using batch queries where possible to optimize for performance. This is all done in native PowerShell, no C# required
   (though C# would allow for certain operations to be even more parallelizable by chaining tasks).

## What this script is not

This is an example of how fast things *can* be, with certain assumptions, but it only works against a single NuGet v2
repository at the moment and is pretty much only tested with PowerShell Gallery. It is *not* a replacement for
PowerShellGet, which has much broader support for multiple repos, authentication, etc.

It makes a lot of very bad assumptions, all of which are safe for PowerShell Gallery at least

1. Nuget v2 Only
1. OData Raw API (vs NuGet functions) is available, which has been deprecated. We use these because they are faster and more documented.
1. Batch API is available
