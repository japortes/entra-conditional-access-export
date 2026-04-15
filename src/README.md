# Export Entra Conditional Access Policies

Exports Microsoft Entra Conditional Access (CA) policies to JSON using the Microsoft Graph PowerShell SDK **Beta API**.

## What it does

- Connects to Microsoft Graph using one of three mutually exclusive auth modes, scoped to the current PowerShell process so it never tears down an existing Graph session in the caller's shell:
  - **Interactive browser sign-in** (default)
  - **Device code flow** (see `-UseDeviceAuthentication`) — useful in headless / SSH sessions
  - **Managed identity** (see `-UseManagedIdentity`) — system-assigned or user-assigned, for unattended automation
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

If you haven't installed Graph PowerShell, or need to upgrade from v1:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser   # fresh install
# Update-Module Microsoft.Graph                     # upgrade from an existing v1 install
```

> Note: This installs both stable (`Microsoft.Graph.*`) and beta (`Microsoft.Graph.Beta.*`) submodules.
> **SDK v2 or later is required** — the script uses `Get-MgBeta*` cmdlets that do not exist in v1.

## Required delegated scopes

> **Note:** Delegated scopes apply only to interactive and device code auth. When using `-UseManagedIdentity`, the identity must be granted the equivalent **app roles** directly (see [Managed identity app roles](#managed-identity-app-roles) below).

The script requests only the scopes needed for the requested operation:

**Always required:**
- `Policy.Read.All`

**Additional (only when `-IncludeDirectoryObjectMappings` is used):**
- `User.Read.All`
- `Group.Read.All`
- `Application.Read.All`
- `Directory.Read.All`

Some scopes commonly require **admin consent** in the tenant.

## Managed identity app roles

When using `-UseManagedIdentity`, the managed identity must be assigned the following **Microsoft Graph app roles** (not delegated scopes) directly on the service principal:

**Always required:**
- `Policy.Read.All`

**Additional (only when `-IncludeDirectoryObjectMappings` is used):**
- `User.Read.All`
- `Group.Read.All`
- `Application.Read.All`
- `Directory.Read.All`

## Required modules

The script checks for and imports these modules on every run:

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Beta.Identity.SignIns` *(Beta — for CA policies, named locations, auth contexts)*

These are only loaded when `-IncludeDirectoryObjectMappings` is used:

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

### Use device code authentication (e.g. headless / SSH sessions)

```powershell
.\src\Export-EntraConditionalAccess.ps1 -UseDeviceAuthentication
```

### Use a system-assigned managed identity (unattended automation)

```powershell
.\src\Export-EntraConditionalAccess.ps1 -UseManagedIdentity
```

The managed identity must have the required Graph app roles assigned (see [Managed identity app roles](#managed-identity-app-roles)).

### Use a user-assigned managed identity

```powershell
.\src\Export-EntraConditionalAccess.ps1 -UseManagedIdentity -ManagedIdentityClientId "<client-or-object-id>"
```

Pass the **client ID** (also called the object ID) of the user-assigned managed identity.
`-UseManagedIdentity` and `-UseDeviceAuthentication` cannot be combined.

### Export for a sovereign cloud

```powershell
.\src\Export-EntraConditionalAccess.ps1 -Environment USGov
```

Supported values: `Global` (default), `USGov`, `USGovDoD`, `China`.

### Target a specific tenant (Tenant ID)

```powershell
.\src\Export-EntraConditionalAccess.ps1 -TenantId "<guid>"
```

### All options combined

```powershell
.\src\Export-EntraConditionalAccess.ps1 `
  -OutFile .\out\entra-conditional-access.json `
  -LogFile .\logs\export.log `
  -IncludeDirectoryObjectMappings `
  -ExportIndividualPolicies `
  -IndividualPoliciesDir .\out\policies `
  -TenantId "<guid>" `
  -Environment Global `
  -UseDeviceAuthentication
```

### Preview writes without making changes (-WhatIf)

The script supports PowerShell's standard `-WhatIf` and `-Confirm` parameters via `SupportsShouldProcess`.
Use `-WhatIf` to see which files would be written without actually writing them:

```powershell
.\src\Export-EntraConditionalAccess.ps1 -ExportIndividualPolicies -WhatIf
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-OutFile` | string | `./entra-conditional-access.json` | Output path for the aggregate JSON file. |
| `-LogFile` | string | *(none)* | If provided, structured log entries with UTC timestamps are appended to this file. |
| `-JsonDepth` | int | `10` | Depth passed to `ConvertTo-Json`. Increase if you see truncated output. |
| `-IncludeDirectoryObjectMappings` | switch | off | Resolves GUIDs in policy conditions to display names and emits a `directoryObjectMappings` section. Also requests additional Graph scopes. |
| `-ExportIndividualPolicies` | switch | off | Exports one JSON file per policy into `IndividualPoliciesDir`. |
| `-IndividualPoliciesDir` | string | `./policies` | Directory for individual policy files (used with `-ExportIndividualPolicies`). |
| `-Environment` | string | `Global` | Microsoft cloud environment. Accepted values: `Global`, `USGov`, `USGovDoD`, `China`. |
| `-TenantId` | string | *(none)* | Target tenant ID (GUID). Passed to `Connect-MgGraph -TenantId`. Works with interactive auth, device code auth, and managed identity. |
| `-UseDeviceAuthentication` | switch | off | Uses device code flow instead of interactive browser sign-in. Useful in headless / SSH sessions. |
| `-UseManagedIdentity` | switch | off | Uses a managed identity (system-assigned or user-assigned) instead of delegated auth. Intended for unattended automation. Incompatible with `-UseDeviceAuthentication`. |
| `-ManagedIdentityClientId` | string | *(none)* | Client/object ID of a **user-assigned** managed identity. Requires `-UseManagedIdentity`. Omit for system-assigned. |

## Pipeline output

After a successful run the script writes a summary object to the pipeline so callers can inspect results without parsing log output:

| Property | Description |
|---|---|
| `OutFile` | Resolved path of the aggregate JSON file that was written |
| `IndividualPoliciesDir` | Directory used for per-policy files, or `$null` if `-ExportIndividualPolicies` was not used |
| `PolicyCount` | Number of policies exported |
| `IncludedDirectoryMappings` | `$true` if `-IncludeDirectoryObjectMappings` was used |
| `Environment` | Cloud environment used |
| `TenantId` | Tenant ID from the connected Graph context |
| `Account` | UPN / account used for the connection |

Example usage:

```powershell
$result = .\src\Export-EntraConditionalAccess.ps1
Write-Host "Exported $($result.PolicyCount) policies to $($result.OutFile)"
```

## Output format

The aggregate JSON file includes:

| Field | Description |
|---|---|
| `exportedAtUtc` | ISO-8601 UTC timestamp of the export |
| `graphApi` | Always `"beta"` |
| `tenantId` | Tenant ID from the connected Graph context |
| `account` | UPN / account used for the connection |
| `environment` | Cloud environment used (`Global`, `USGov`, etc.) |
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
- The script supports `-WhatIf` and `-Confirm` via PowerShell's `SupportsShouldProcess` mechanism.
  Use `-WhatIf` to preview which files would be written without actually writing any output.
