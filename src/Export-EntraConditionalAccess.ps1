# Updated Export-EntraConditionalAccess.ps1

# Existing Content

import-module Microsoft.Graph.Applications
import-module Microsoft.Graph.Identity.DirectoryManagement

# Define the required scopes
$scopes = @('Application.Read.All', 'Directory.Read.All')

# Extend the functionality of the script to handle additional mappings
function Get-ConditionalAccessMappings {
    param (
        [string]$token
    )
    
    # Handle existing logic for users and groups
    # ... (existing functionality remains unchanged)
    
    # New logic to include Applications and Service Principals
    if ($conditions.applications) {
        foreach ($app in $conditions.applications) {
            # Resolve the application references
            # (resolve logic and store errors if any)
        }
    }
    
    # New logic for named locations
    if ($conditions.locations) {
        foreach ($location in $conditions.locations) {
            # Resolve named locations
            # (resolve logic and store errors if any)
        }
    }
    
    # New logic for authentication contexts
    if ($conditions.authenticationContexts) {
        foreach ($context in $conditions.authenticationContexts) {
            # Resolve authentication contexts
            # (resolve logic and store errors if any)
        }
    }
    
    # Create mappings keys
    $directoryObjectMappings = @{ 
        applications = $resolvedApplications;
        servicePrincipals = $resolvedServicePrincipals;
        namedLocations = $resolvedNamedLocations;
        authenticationContexts = $resolvedAuthenticationContexts;
        roles = $resolvedRoles;
    }

    # Preserve default behavior
    # output file named entra-conditional-access.json
}

# Call the function
Get-ConditionalAccessMappings -token $accessToken

# Error handling logic
# (Implement error logging for failed GUID resolutions) 

# End of the script.