# Export Entra Conditional Access Policies

## Prerequisites
- [Microsoft Graph PowerShell](https://www.powershellgallery.com/packages/Microsoft.Graph)
- Azure AD administrative permissions

## Installation
To install the Microsoft Graph module, run the following command:
```powershell
Install-Module Microsoft.Graph
```

## Usage
1. Open PowerShell and run the following command to start the script:
```powershell
.
Export-EntraConditionalAccess.ps1
```

2. You will be prompted to sign in. Use an account with admin privileges.

## Notes
- Ensure you grant admin consent for the `Policy.Read.All` permission.
- This script allows you to choose between the v1.0 and beta profiles. The v1.0 profile is recommended for production environments.
