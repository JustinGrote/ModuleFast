---
document type: cmdlet
external help file: ModuleFast.dll-Help.xml
HelpUri: ''
Locale: en-US
Module Name: ModuleFast
ms.date: 07/17/2026
PlatyPS schema version: 2024-05-01
title: Clear-ModuleFastCache
sidebar:
  order: 2
---

# Clear-ModuleFastCache

## SYNOPSIS

Clears the in-memory HTTP request cache used by ModuleFast.

## SYNTAX

### __AllParameterSets

```
Clear-ModuleFastCache
```

## ALIASES

This cmdlet has no aliases.

## DESCRIPTION

ModuleFast caches repository metadata for the lifetime of the PowerShell session. Use this command after publishing a new module version or when a subsequent plan must fetch repository metadata again.

## EXAMPLES

### Example 1

Clears cached repository responses so the next plan performs fresh lookups.

```powershell
Clear-ModuleFastCache
```

## PARAMETERS

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### System.Object

System.Object. The command does not produce pipeline output.

## NOTES

The cache is recreated immediately and remains empty until another ModuleFast operation queries a repository.

## RELATED LINKS

[Install-ModuleFast](Install-ModuleFast.md)

