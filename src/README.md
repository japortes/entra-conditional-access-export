# Export Entra Conditional Access Policies

Exports Microsoft Entra Conditional Access (CA) policies to JSON using the Microsoft Graph PowerShell SDK.

## What it does

- Connects to Microsoft Graph using **interactive sign-in** (delegated permissions).
- Exports all Conditional Access policies to a JSON file (default: `entra-conditional-access.json`).
- Optionally performs **best-effort GUID → friendly name** resolution for objects referenced by policy conditions:
  - users
  - groups
  - applications and service principals
  - named locations
  - authentication contexts (best-effort; depends on Graph SDK/profile support)
  - roles (best-effort; may be directory roles or role templates)

If a referenced object can’t be resolved (deleted object, insufficient permissions, missing cmdlet, etc.), the export still completes and the mapping entry will include an error message.

## Prerequisites

- PowerShell 7+ recommended (Windows PowerShell 5.1 often works too)
- Microsoft Graph PowerShell SDK modules (see **Required modules** below)
- An account that can consent to / use the required delegated permissions

## Installation

If you haven’t installed Graph PowerShell:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

> Note: This repo imports specific submodules. Installing the meta-module `Microsoft.Graph` typically provides them.

## Required delegated scopes

The script connects with these delegated scopes:

- `Policy.Read.All`
- `User.Read.All`
- `Group.Read.All`
- `Application.Read.All`
- `Directory.Read.All`

Some scopes commonly require **admin consent** in the tenant.

## Required modules

The script checks for and imports these modules:

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Identity.SignIns`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Applications`
- `Microsoft.Graph.DirectoryObjects`
- `Microsoft.Graph.Identity.DirectoryManagement`

If a module is missing, the script stops with an install hint.

## Usage

Run the script from the repo root (or provide the full path).

### Basic export (policies only)

```powershell
.\src\Export-EntraConditionalAccess.ps1
```

This writes `entra-conditional-access.json` into the current directory.

### Specify output file

```powershell
.\src\Export-EntraConditionalAccess.ps1 -OutFile .\out\entra-conditional-access.json
```

### Choose Graph profile (v1.0 or beta)

Default is `v1.0`.

```powershell
.\src\Export-EntraConditionalAccess.ps1 -GraphProfile beta
```

### Include directory object mappings (GUID → friendly names)

```powershell
.\src\Export-EntraConditionalAccess.ps1 -IncludeDirectoryObjectMappings
```

## Parameters

- `-OutFile` (string)  
  Output JSON path. Defaults to `./entra-conditional-access.json`.

- `-GraphProfile` (string: `v1.0` | `beta`)  
  Graph profile to use. Default: `v1.0`.

- `-JsonDepth` (int)  
  JSON serialization depth passed to `ConvertTo-Json`. Default: `80`.

- `-IncludeDirectoryObjectMappings` (switch)  
  If set, the script attempts to resolve IDs referenced in policy conditions and emits a `directoryObjectMappings` object in the output.

## Output format

The JSON output includes:

- `exportedAtUtc`
- `graphProfile`
- `tenantId`
- `account`
- `policyCount`
- `policies` (raw policy objects returned by Graph PowerShell)
- `directoryObjectMappings` (only when `-IncludeDirectoryObjectMappings` is used)

## Notes / behavior details

- Mapping resolution is **best-effort** and will **never fail the export**.
- Non-GUID tokens sometimes present in CA policy collections (e.g., `All`, `None`) are ignored for mapping.
- The script sets strict mode and uses `ErrorActionPreference = Stop`, but individual mapping lookups are isolated so that lookup failures don’t abort the overall export.
