# Entra Conditional Access Export (PowerShell)

Exports Microsoft Entra Conditional Access (CA) policy configuration to JSON using Microsoft Graph PowerShell.
Supports **interactive**, **device code**, and **managed identity** authentication.

## Quick start

```powershell
# Install required modules (v2+ required; upgrade if you already have v1 installed)
Install-Module Microsoft.Graph -Scope CurrentUser   # fresh install
# Update-Module Microsoft.Graph                     # upgrade from an existing v1 install

# Run export (default output: entra-conditional-access.json, interactive sign-in)
.\src\Export-EntraConditionalAccess.ps1

# Run export and include GUID->name mappings for referenced users/groups
.\src\Export-EntraConditionalAccess.ps1 -IncludeDirectoryObjectMappings

# Run export using device code (headless/SSH sessions)
.\src\Export-EntraConditionalAccess.ps1 -UseDeviceAuthentication

# Run export using a system-assigned managed identity (unattended automation)
.\src\Export-EntraConditionalAccess.ps1 -UseManagedIdentity

# Run export using a user-assigned managed identity (client ID shown on MI's Overview page in the portal)
.\src\Export-EntraConditionalAccess.ps1 -UseManagedIdentity -ManagedIdentityClientId "<client-id>"
```

## Output
- Default file: `entra-conditional-access.json`
- Includes:
  - CA policies returned by Microsoft Graph
  - (optional) `directoryObjectMappings` for users, groups, apps, locations, auth contexts, and roles referenced in policy conditions
- Optional per-policy individual JSON files (see `-ExportIndividualPolicies`)

## Details
See `src/README.md` for prerequisites and notes.
