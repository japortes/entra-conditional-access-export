# Export Entra Conditional Access Policies

Exports Microsoft Entra Conditional Access (CA) policies to JSON using the Microsoft Graph PowerShell SDK **Beta API**.

## What it does

- Connects to Microsoft Graph using **interactive sign-in** (delegated permissions).
- Uses `Get-MgBetaIdentityConditionalAccessPolicy -All` to capture the full policy state and all
  condition objects: `users`, `applications`, `clientAppTypes`, `locations`, `deviceStates`,
  `platforms`, `signInRiskLevels`, `userRiskLevels`, `guestOrExternalUserTypes`, etc.
- **Microsoft-managed policies** (`isSystemManaged = true`) are included automatically via `-All`.
- Exports all policies to a single aggregate JSON file with export metadata (default: `entra-conditional-access.json`).
- Policies and all internal primitive arrays are **sorted** before serialization for consistent,
  diff-friendly output.
- Optionally performs **best-effort GUID → friendly name** resolution for objects referenced by policy conditions:
  - users
  - groups
  - applications and service principals
  - named locations
  - authentication contexts
  - roles (directory roles or role templates)
- Optionally exports **individual per-policy JSON files** with automatic duplicate `DisplayName` handling.
- Optionally writes a **structured log file** with UTC timestamps for every operation.

If a referenced object can't be resolved (deleted object, insufficient permissions, missing cmdlet, etc.), the export still completes and the mapping entry will include an error message.

## Prerequisites

- PowerShell 7+ recommended (Windows PowerShell 5.1 often works too)
- Microsoft Graph PowerShell SDK **v2+** (uses `Get-MgBeta*` cmdlets)
- An account that can consent to / use the required delegated permissions

## Installation

If you haven't installed Graph PowerShell:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

> Note: This installs both stable (`Microsoft.Graph.*`) and beta (`Microsoft.Graph.Beta.*`) submodules.

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
- `Microsoft.Graph.Beta.Identity.SignIns` *(Beta — for CA policies, named locations, auth contexts)*
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

### Write a structured log file

```powershell
.\src\Export-EntraConditionalAccess.ps1 -LogFile .\logs\export.log
```

### Include directory object mappings (GUID → friendly names)

```powershell
.\src\Export-EntraConditionalAccess.ps1 -IncludeDirectoryObjectMappings
```

### Export individual per-policy JSON files

```powershell
.\src\Export-EntraConditionalAccess.ps1 -ExportIndividualPolicies
```

This creates a `policies/` subdirectory in the current directory and writes one JSON file per policy.
Policies with duplicate `DisplayName` values are disambiguated by appending the policy GUID.

### Specify the individual-policies output directory

```powershell
.\src\Export-EntraConditionalAccess.ps1 -ExportIndividualPolicies -IndividualPoliciesDir .\out\policies
```

### All options combined

```powershell
.\src\Export-EntraConditionalAccess.ps1 `
  -OutFile .\out\entra-conditional-access.json `
  -LogFile .\logs\export.log `
  -IncludeDirectoryObjectMappings `
  -ExportIndividualPolicies `
  -IndividualPoliciesDir .\out\policies
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-OutFile` | string | `./entra-conditional-access.json` | Output path for the aggregate JSON file. |
| `-LogFile` | string | *(none)* | If provided, structured log entries with UTC timestamps are appended to this file. |
| `-JsonDepth` | int | `10` | Depth passed to `ConvertTo-Json`. Increase if you see truncated output. |
| `-IncludeDirectoryObjectMappings` | switch | off | Resolves GUIDs in policy conditions to display names and emits a `directoryObjectMappings` section. |
| `-ExportIndividualPolicies` | switch | off | Exports one JSON file per policy into `IndividualPoliciesDir`. |
| `-IndividualPoliciesDir` | string | `./policies` | Directory for individual policy files (used with `-ExportIndividualPolicies`). |

## Output format

The aggregate JSON file includes:

| Field | Description |
|---|---|
| `exportedAtUtc` | ISO-8601 UTC timestamp of the export |
| `graphApi` | Always `"beta"` |
| `tenantId` | Tenant ID from the connected Graph context |
| `account` | UPN / account used for the connection |
| `policyCount` | Number of policies returned |
| `policies` | Array of policy objects (sorted by `DisplayName`; internal arrays sorted) |
| `directoryObjectMappings` | GUID → name maps (only when `-IncludeDirectoryObjectMappings` is used) |

## Notes / behavior details

- The script uses `Get-MgBeta*` cmdlets — **Microsoft Graph PowerShell SDK v2+** is required.
  (`Select-MgProfile` is no longer used; the API tier is determined by the cmdlet prefix.)
- Mapping resolution is **best-effort** and will **never fail the export**.
- Non-GUID tokens sometimes present in CA policy collections (e.g., `All`, `None`) are ignored for mapping.
- The script sets strict mode and `ErrorActionPreference = Stop`, but individual mapping lookups are
  isolated so lookup failures don't abort the export.
- When `-ExportIndividualPolicies` is used, policies with the same `DisplayName` are disambiguated by
  appending `_<policyId>` to the filename.
