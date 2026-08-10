---
document type: module
Help Version: 1.0.0.0
HelpInfoUri: 
Locale: en-US
Module Guid: 89fcb0cf-1a4e-4dbf-92f5-10ce3eae241f
Module Name: ModuleFast
ms.date: 07/17/2026
PlatyPS schema version: 2024-05-01
title: ModuleFast Module
sidebar:
  order: 1
---

# ModuleFast Module

## Description

ModuleFast is a high-performance, declarative PowerShell module installer. It resolves dependencies in parallel, supports SemVer and prerelease constraints, and can install requirements from scripts, module manifests, and lockfiles for reproducible CI/CD builds.

## Quick Start

ModuleFast can be bootstrapped without PowerShellGet or another package manager:

```powershell
iwr bit.ly/modulefast | iex
Install-ModuleFast ImportExcel
```

The module is also available through the `imf` alias. To inspect the complete command help after bootstrapping:

```powershell
iwr bit.ly/modulefast | iex
Get-Help Install-ModuleFast -Full
```

For CI/CD or other one-shot environments, download and invoke the script directly:

```powershell
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) -Specification ImportExcel
```

Pin the bootstrap script to a release when reproducibility is more important than automatically receiving the latest version:

```powershell
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) -Release 'v0.6.1' -Specification ImportExcel
```

## ModuleFast Commands

### [Clear-ModuleFastCache](Clear-ModuleFastCache.md)

Clears the in-memory HTTP request cache used by ModuleFast.

### [Install-ModuleFast](Install-ModuleFast.md)

Installs PowerShell modules and their dependencies from specifications or requirement files.

## AnyPackage

ModuleFast can be used as an [AnyPackage](https://github.com/anypackage/anypackage) provider:

```powershell
& ([scriptblock]::Create((iwr 'bit.ly/modulefast'))) -Specification AnyPackage.ModuleFast
Import-Module AnyPackage.ModuleFast
AnyPackage\Install-Package -Provider ModuleFast -Name 'ImportExcel<4', 'Pester<4'
```

## Module Specification Syntax

Specifications generally have the form `<ModuleName><Operator><Version>`. Versions support SemVer 2 and prerelease labels.

| Operator | Meaning | Example |
| --- | --- | --- |
| `=` | Exact version | `ImportExcel=7.1.0` |
| `>` | Greater than | `ImportExcel>7.1.0` |
| `>=` | Greater than or equal to | `ImportExcel>=7.1.0` |
| `<` | Less than | `ImportExcel<7.1.0` |
| `<=` | Less than or equal to | `ImportExcel<=7.1.0` |
| `!` | Allow prerelease versions | `ImportExcel!`, `!ImportExcel` |
| `:` | NuGet version range or floating version | `ImportExcel:(7.0.0,7.2.1-preview]`, `ImportExcel:3.2.*` |

The `!` operator can be combined with a version operator, for example `ImportExcel!>7.1.0`. ModuleFast also accepts PowerShell `ModuleSpecification` objects, compatible hashtables, and `ModuleFastInfo` plans.

For complete NuGet range syntax, see [NuGet version ranges](https://learn.microsoft.com/en-us/nuget/concepts/package-versioning#version-ranges). For the standard PowerShell object and hashtable format, see [about_Requires](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_requires).

Without `-StrictSemVer`, ModuleFast applies a user-friendly prerelease rule to exclusive upper bounds. For example, `Module<2.0` does not select `2.0-alpha`, even though that version is lower than `2.0` according to SemVer. Use `-StrictSemVer` when strict NuGet behavior is required.

## Dependency Resolution

ModuleFast builds a dependency tree and selects the newest versions that satisfy every requirement. An installed module is reused when it satisfies the specification, which avoids unnecessary downloads. Specify `-Update` to check the repository for newer versions.

Use `-Plan` to preview the pipeline-friendly installation plan, or `-WhatIf` to preview the plan using PowerShell's ShouldProcess output. Plans can be piped to a later `Install-ModuleFast` invocation or serialized for a separate installation stage.

## Requirement Files

The `-Path` parameter accepts the following requirement sources:

- PowerShell scripts (`.ps1`) with `#Requires -Module` statements
- PowerShell modules (`.psm1`) with `#Requires -Module` statements
- Module manifests (`.psd1`) with a `RequiredModules` property
- ModuleFast, PSResourceGet, and PSDepend `.psd1` formats
- JSON files containing module/version pairs or an array of specification strings

When no specification or path is supplied, ModuleFast searches the current directory for `.requires.psd1`, `.requires.json`, `.requires.jsonc`, `.requires.ps1`, and `.requires.psm1` files. A requirement file can use `latest` or `:*` to request the newest matching version.

## CI Lockfiles

Use `-CI` to write `requires.lock.json` with the exact versions resolved during installation:

```powershell
Install-ModuleFast ImportExcel -CI
```

On a later run in the same directory, `Install-ModuleFast -CI` uses the lockfile so the build remains reproducible even when newer repository versions are released. Commit the lockfile with the project when this behavior is desired.

## Installation Path

By default, ModuleFast installs to the current user's PowerShell module path. On Windows it uses the local application data module directory by default to avoid conflicts with document-sync software. `-Destination` selects an explicit path, and `-Scope CurrentUser` selects the legacy Documents module path on Windows.

ModuleFast adds its default destination to the current session's `PSModulePath` and may add it to the user's PowerShell profile. Use `-NoPSModulePathUpdate` or `-NoProfileUpdate` to disable those updates. Use `-DestinationOnly` when planning in an isolated CI destination.

## Logging and Cache

Use `-Verbose` for a high-level account of module selection and installation. Use `-Debug` for detailed dependency and candidate-selection diagnostics. ModuleFast caches repository metadata for the lifetime of the PowerShell session; run [Clear-ModuleFastCache](Clear-ModuleFastCache.md) to force subsequent requests to fetch fresh metadata.

## Platform and Repository Requirements

ModuleFast requires PowerShell 7.2 or later and a NuGet v3-compatible HTTPS repository. The default repository is [pwsh.gallery](https://github.com/justingrote/gallerysync). Third-party repositories using HTTPS Basic authentication can be selected with `-Source` and `-Credential`.

ModuleFast is designed for fast, declarative installation and is not a drop-in replacement for PowerShellGet. It does not support NuGet v2 repositories, and it currently does not install modules from local file shares.

## Related Links

- [ModuleFast GitHub repository](https://github.com/JustinGrote/ModuleFast)
- [ModuleFast GitHub Action](https://github.com/marketplace/actions/modulefast)
- [Install-ModuleFast](Install-ModuleFast.md)
- [Clear-ModuleFastCache](Clear-ModuleFastCache.md)

