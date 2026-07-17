---
document type: cmdlet
external help file: ModuleFast.dll-Help.xml
HelpUri: ''
Locale: en-US
Module Name: ModuleFast
ms.date: 07/17/2026
PlatyPS schema version: 2024-05-01
title: Install-ModuleFast
---

# Install-ModuleFast

## SYNOPSIS

High-performance, declarative PowerShell module installer.

## SYNTAX

### Specification (Default)

```
Install-ModuleFast [[-Specification] <ModuleFastSpec[]>] [-Destination <string>] [-Source <string>]
 [-Credential <pscredential>] [-NoPSModulePathUpdate] [-NoProfileUpdate] [-Update] [-Prerelease]
 [-CI] [-DestinationOnly] [-ThrottleLimit <int>] [-CILockFilePath <string>] [-Plan] [-PassThru]
 [-Scope <InstallScope>] [-Timeout <int>] [-StrictSemVer] [-WhatIf] [-Confirm]
```

### Path

```
Install-ModuleFast -Path <string> [-SpecFileType <SpecFileType>] [-Destination <string>]
 [-Source <string>] [-Credential <pscredential>] [-NoPSModulePathUpdate] [-NoProfileUpdate]
 [-Update] [-Prerelease] [-CI] [-DestinationOnly] [-ThrottleLimit <int>] [-CILockFilePath <string>]
 [-Plan] [-PassThru] [-Scope <InstallScope>] [-Timeout <int>] [-StrictSemVer] [-WhatIf] [-Confirm]
```

### ModuleFastInfo

```
Install-ModuleFast -ModuleFastInfo <ModuleFastInfo[]> [-Destination <string>] [-Source <string>]
 [-Credential <pscredential>] [-NoPSModulePathUpdate] [-NoProfileUpdate] [-Update] [-Prerelease]
 [-CI] [-DestinationOnly] [-ThrottleLimit <int>] [-CILockFilePath <string>] [-Plan] [-PassThru]
 [-Scope <InstallScope>] [-Timeout <int>] [-StrictSemVer] [-WhatIf] [-Confirm]
```

## ALIASES

This cmdlet has the following aliases: `imf`

## DESCRIPTION

Installs the newest modules that satisfy the supplied specifications and recursively resolves their dependencies. Specifications can be shorthand strings such as `ImportExcel=7.8.6`, `Module>=1.0.0`, or `Module:(1.0.0,2.0.0]`; `ModuleSpecification` objects, compatible hashtables, and `ModuleFastInfo` plans are also supported.

Use `-Plan` to return the modules that would be installed without changing the system. Use `-WhatIf` for the same plan together with PowerShell's ShouldProcess preview. With no specification or path, ModuleFast searches the current directory for supported `*.requires.*` files. The `-Path` parameter can also read a script or module `#Requires` statement, a module manifest, JSON, or PSDepend-style data.

By default, already-installed modules that satisfy a specification are reused. `-Update` checks the repository for newer candidates, `-Prerelease` includes prerelease packages, and `-StrictSemVer` enables strict NuGet range behavior for prereleases at an exclusive upper bound.

## EXAMPLES

### Example 1

Installs the latest stable version of `ImportExcel` and its dependencies, then returns information about modules installed by this invocation.

```powershell
Install-ModuleFast 'ImportExcel' -PassThru
```

### Example 2

Builds a plan containing a latest module, an exact version, an upper bound, and a floating `7.1.x` version. `-Plan` returns the plan without installing anything.

```powershell
Install-ModuleFast 'ImportExcel', 'VMware.PowerCLI.Sdk=12.6.0.19600125', 'PowerConfig<0.1.6', 'Az.Compute:7.1.*' -Plan
```

### Example 3

The specification parameter accepts pipeline input.

```powershell
'ImportExcel', 'VMware.PowerCLI.Sdk=12.6.0.19600125', 'PowerConfig<0.1.6', 'Az.Compute:7.1.*' |
  Install-ModuleFast -Plan
```

### Example 4

A plan can be saved and passed to a later invocation. Plan objects can be serialized to CLIXML or JSON when a build needs to separate resolution from installation.

```powershell
$plan = Install-ModuleFast 'ImportExcel' -Plan
$plan | Install-ModuleFast -PassThru
```

### Example 5

Installs a specific version using the standard PowerShell module specification hashtable syntax.

```powershell
@{ ModuleName = 'ImportExcel'; RequiredVersion = '7.8.6' } |
  Install-ModuleFast -PassThru
```

### Example 6

Plans dependencies declared by a script's `#Requires -Module` statement. The same form works with a `.psm1` file or a `.psd1` manifest containing `RequiredModules`.

```powershell
Install-ModuleFast -Path './RequiresScript.ps1' -Plan
```

### Example 7

When no specification or path is supplied, ModuleFast searches the current directory for a `.requires.psd1`, `.requires.json`, `.requires.jsonc`, `.requires.ps1`, or `.requires.psm1` file.

```powershell
Install-ModuleFast -Plan
```

### Example 8

Creates a lockfile containing the exact versions resolved for the build, then uses that lockfile on later runs.

```powershell
Install-ModuleFast 'ImportExcel' -CI
Install-ModuleFast -CI
```

## PARAMETERS

### -CI

Writes a `requires.lock.json` file containing the exact module versions resolved by the command. When the lockfile exists, a later `-CI` invocation installs those pinned versions instead of resolving the original specifications again.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -CILockFilePath

Overrides the default lockfile path, which is `requires.lock.json` in the current directory. This parameter is used only with `-CI`.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Confirm

Prompts you for confirmation before running the cmdlet.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases:
- cf
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Credential

Supplies credentials for a NuGet v3 source using HTTP Basic authentication. This is useful for authenticated private repositories.

```yaml
Type: System.Management.Automation.PSCredential
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Destination

Sets the module installation directory. If omitted, ModuleFast uses the current user's default PowerShell module path. Specifying a path also suppresses profile updates.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -DestinationOnly

Checks only `-Destination` for installed modules when planning. This is useful in isolated or CI environments where modules in other `PSModulePath` entries must be ignored.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -ModuleFastInfo

Accepts `ModuleFastInfo` objects produced by `-Plan` and installs that previously resolved plan. This parameter accepts pipeline input.

```yaml
Type: ModuleFast.ModuleFastInfo[]
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: ModuleFastInfo
  Position: Named
  IsRequired: true
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -NoProfileUpdate

Prevents ModuleFast from adding its default destination to the current user's PowerShell profile.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -NoPSModulePathUpdate

Prevents ModuleFast from adding the destination to the current session's `PSModulePath`. This also prevents the related profile update.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -PassThru

Returns the modules installed by this invocation as `ModuleFastInfo` objects.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Path

Reads module requirements from a local file, directory, or HTTP/HTTPS URL. Supported files include scripts and modules with `#Requires -Module`, manifests with `RequiredModules`, ModuleFast/PSResourceGet/PSDepend data files, and JSON requirement files.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: Path
  Position: Named
  IsRequired: true
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Plan

Returns the resolved installation plan without installing modules. This is the pipeline-friendly equivalent of `-WhatIf` without the additional ShouldProcess preview text.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Prerelease

Includes prerelease packages when resolving specifications. Version constraints still apply.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Scope

Selects the default installation scope. `CurrentUser` uses the legacy Documents module path on Windows; `AllUsers` uses the all-users default path when supported.

```yaml
Type: System.Nullable`1[ModuleFast.InstallScope]
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Source

Specifies the NuGet v3 repository to query. The default is `https://pwsh.gallery/index.json`.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -SpecFileType

Selects the format of a `.psd1` requirement file. `AutoDetect` is the default and recognizes ModuleFast, PSResourceGet, and PSDepend formats.

```yaml
Type: ModuleFast.SpecFileType
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: Path
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Specification

Specifies one or more modules to install. Values may be shorthand strings, `ModuleSpecification` objects, compatible hashtables, or `ModuleFastSpec` objects. The parameter accepts pipeline input and has aliases `-Name`, `-ModuleToInstall`, and `-ModulesToInstall`.

```yaml
Type: ModuleFast.ModuleFastSpec[]
DefaultValue: ''
SupportsWildcards: false
Aliases:
- Name
- ModuleToInstall
- ModulesToInstall
ParameterSets:
- Name: Specification
  Position: 0
  IsRequired: false
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -StrictSemVer

Uses strict NuGet SemVer range behavior. In particular, an exclusive upper bound such as `Module!<2.0.0` may include `2.0.0-alpha` when this switch is specified.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -ThrottleLimit

Sets the maximum number of concurrent module extraction jobs. The default is the number of logical processors.

```yaml
Type: System.Int32
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Timeout

Sets the HTTP request timeout in seconds. The default is 30 seconds.

```yaml
Type: System.Int32
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Update

Checks the repository for newer versions even when an installed module satisfies the specification. This also clears cached repository lookups.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -WhatIf

Runs the command in a mode that only reports what would happen without performing the actions.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases:
- wi
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### ModuleFast.ModuleFastSpec[]

Accepts `ModuleFastSpec[]` specifications or `ModuleFastInfo[]` plans from the pipeline.

### ModuleFast.ModuleFastInfo[]

Returns `ModuleFastInfo` objects for modules that are installed or planned.

## OUTPUTS

### ModuleFast.ModuleFastInfo

Returns information about modules installed by the current invocation when `-PassThru` is specified.

## NOTES

ModuleFast requires PowerShell 7.2 or later and a NuGet v3-compatible repository. Use `-NoPSModulePathUpdate` and `-NoProfileUpdate` for isolated automation, and use `-DestinationOnly` when the destination must be self-contained.

## RELATED LINKS

[Clear-ModuleFastCache](Clear-ModuleFastCache.md)

