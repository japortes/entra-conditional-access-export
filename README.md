# Entra Conditional Access Export (PowerShell)

Exports Microsoft Entra Conditional Access (CA) policy configuration to JSON using Microsoft Graph PowerShell with **interactive sign-in**.

## Quick start

```powershell
# Install required modules
Install-Module Microsoft.Graph -Scope CurrentUser

# Run export (v1.0 profile, default output entra-conditional-access.json)
.\src\Export-EntraConditionalAccess.ps1

# Run export and include GUID->name mappings for referenced users/groups
.\src\Export-EntraConditionalAccess.ps1 -IncludeDirectoryObjectMappings
```

## Output
- Default file: `entra-conditional-access.json`
- Includes:
  - CA policies returned by Microsoft Graph
  - (optional) `directoryObjectMappings` for users and groups referenced in policy conditions

## Details
See `src/README.md` for prerequisites and notes.
