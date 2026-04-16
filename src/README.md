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
  - **Users** and **groups** are resolved via the Graph `/$batch` endpoint (up to 20 requests per batch call).
  - **Applications / service principals** are also batched in a two-pass strategy: every ID is attempted as a `servicePrincipal` object first; any IDs not found there fall through to an `application` object lookup.
  - **Named locations**, **authentication contexts**, and **roles** are resolved individually (one request per object).
  - **Roles**: DirectoryRole objects are attempted first. If that lookup fails (logged as `[WARN]`), the ID is retried as a DirectoryRoleTemplate. Failed lookups in both passes are recorded with an `error` field. The `[WARN]` log on a DirectoryRole miss is expected in tenants that reference role templates directly and does not indicate a problem.
- Optionally exports **individual per-policy JSON files** with automatic duplicate `DisplayName` handling.
- Optionally writes a **structured log file** with UTC timestamps for every operation.

If a referenced object can't be resolved (deleted object, insufficient permissions, missing cmdlet, etc.), the export still completes and the mapping entry will include an error message.

When `-IncludeDirectoryObjectMappings` is used the log now includes a count and a short sample of GUIDs being resolved for each category (users, groups, apps/SPs, locations, auth contexts, roles), so you can confirm which IDs were attempted without digging into the JSON.

The named-location lookup automatically detects whether the installed Microsoft Graph PowerShell SDK version exposes the parameter as `-ConditionalAccessNamedLocationId` or `-NamedLocationId` and selects the correct one, avoiding parameter-name mismatch errors across SDK versions.

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

> After connecting, the script verifies that all requested scopes were actually granted. If any scope is missing (e.g. admin consent not yet given), the script throws a descriptive error listing the missing scopes before attempting any API calls.

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
Policy filenames are sanitised as follows:

- Characters `\ / : * ? " < > |` are replaced with `_`.
- Multiple consecutive whitespace characters are collapsed to a single space; leading/trailing spaces and periods are stripped.
- Repeated underscores are collapsed to a single `_`.
- Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9`) have `_policy` appended.
- Base names are truncated to **120 characters** (before the `.json` extension).
- If the resulting name (after sanitisation) collides with an already-used filename, the policy GUID is appended: `<name>_<policyId>.json`.

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
.\src\Export-EntraConditionalAccess.ps1 -UseManagedIdentity -ManagedIdentityClientId "<client-id>"
```

Pass the **client ID** (application ID) of the user-assigned managed identity. This is shown as "Client ID" on the managed identity's Overview page in the Azure portal — it is distinct from the object ID.
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

> **Note:** `-WhatIf` only suppresses file-write operations. All Graph API calls (authentication, policy retrieval, and GUID resolution) still execute normally.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-OutFile` | string | `./entra-conditional-access.json` | Output path for the aggregate JSON file. The parent directory is created automatically if it does not exist. |
| `-LogFile` | string | *(none)* | If provided, structured log entries with UTC timestamps are appended to this file. The parent directory is created automatically if it does not exist. |
| `-JsonDepth` | int | `10` | Depth passed to `ConvertTo-Json`. Increase if you see truncated output. |
| `-IncludeDirectoryObjectMappings` | switch | off | Resolves GUIDs in policy conditions to display names and emits a `directoryObjectMappings` section. Also requests additional Graph scopes. |
| `-ExportIndividualPolicies` | switch | off | Exports one JSON file per policy into `IndividualPoliciesDir`. |
| `-IndividualPoliciesDir` | string | `./policies` | Directory for individual policy files (used with `-ExportIndividualPolicies`). Created automatically if it does not exist. |
| `-Environment` | string | `Global` | Microsoft cloud environment. Accepted values: `Global`, `USGov`, `USGovDoD`, `China`. |
| `-TenantId` | string | *(none)* | Target tenant ID (GUID). Passed to `Connect-MgGraph -TenantId`. Works with interactive auth, device code auth, and managed identity. |
| `-UseDeviceAuthentication` | switch | off | Uses device code flow instead of interactive browser sign-in. Useful in headless / SSH sessions. |
| `-UseManagedIdentity` | switch | off | Uses a managed identity (system-assigned or user-assigned) instead of delegated auth. Intended for unattended automation. Incompatible with `-UseDeviceAuthentication`. |
| `-ManagedIdentityClientId` | string | *(none)* | **Client ID** (application ID) of a user-assigned managed identity. Requires `-UseManagedIdentity`. Omit for system-assigned. |

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
| `directoryObjectMappings` | Always present in the JSON output. Contains GUID → name maps when `-IncludeDirectoryObjectMappings` is used; `null` otherwise. `servicePrincipals`: all app-like IDs are first attempted as service-principal objects. If not found, an application-object lookup is performed. IDs that fail both passes are recorded under `servicePrincipals` (not `applications`) with an `error` field. |

## Notes / behavior details

- The script uses `Get-MgBeta*` cmdlets — **Microsoft Graph PowerShell SDK v2+** is required.
  (`Select-MgProfile` is no longer used; the API tier is determined by the cmdlet prefix.)
- The script automatically retries transient Graph API failures (HTTP 429, 5xx) with up to 5 attempts, honouring the server's `Retry-After` header when present and falling back to exponential back-off (2 s, 4 s, 8 s, …).
- The script connects to Graph with `-ContextScope Process`, which scopes the session to the current PowerShell process. This means it will not tear down an existing Graph connection in the caller's shell, and the script's own session persists for the lifetime of the process. `Disconnect-MgGraph` is not called on exit.
- If the aggregate output file (`-OutFile`) already exists it will be **overwritten**; the script logs a `[WARN]` message before doing so. There is no append mode — every run produces a fresh file.
- Object traversal during pre-serialisation sorting is capped at **20 levels** (controlled by `$script:_maxTraversalDepth` in the script source). This cap is independent of `-JsonDepth`. If a one-time `[WARN]` message about traversal depth appears in your log, increase `$script:_maxTraversalDepth` in the script. In practice, Beta CA policy objects are ~5–6 levels deep, so this cap is only hit by unusually nested structures.
- Mapping resolution is **best-effort** and will **never fail the export**.
- Non-GUID tokens sometimes present in CA policy collections (e.g., `All`, `None`) are ignored for mapping.
- `includeUserActions` values found in policy application conditions are intentionally excluded from GUID mapping — they are string action identifiers, not object GUIDs.
- Authentication context IDs are collected from both the `AuthenticationContexts` and `AuthenticationContextClassReferences` properties on the `Conditions` object (the property name varies across Graph SDK versions). Duplicate IDs across both properties are deduplicated before resolution.
- The named-location lookup automatically detects whether the installed SDK exposes the parameter as `-ConditionalAccessNamedLocationId` or `-NamedLocationId` and adapts accordingly. If neither is detected, all named-location lookups are skipped and an explanatory `[WARN]` is logged.
- The script sets strict mode and `ErrorActionPreference = Stop`, but individual mapping lookups are
  isolated so lookup failures don't abort the export.
- When `-ExportIndividualPolicies` is used, policies with the same `DisplayName` are disambiguated by
  appending `_<policyId>` to the filename.
- The script supports `-WhatIf` and `-Confirm` via PowerShell's `SupportsShouldProcess` mechanism.
  `-WhatIf` only suppresses file-write operations. All Graph API calls (authentication, policy retrieval, and GUID resolution) still execute normally.
