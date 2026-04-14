<#
.SYNOPSIS
  Exports Microsoft Entra Conditional Access policies to JSON via Microsoft Graph PowerShell.

.DESCRIPTION
  Uses interactive sign-in (delegated permissions). Writes a JSON file containing CA policies.
  Optionally includes friendly-name mappings for GUIDs referenced by policies (users, groups, apps,
  service principals, named locations, authentication contexts, and roles where possible).

  Output file defaults to entra-conditional-access.json.

.NOTES
  - This script is designed to be resilient: mapping resolution is best-effort and will never fail
    the export if a particular GUID can't be resolved (insufficient permissions, object deleted, etc).
  - Some CA policy fields contain non-GUID tokens (e.g., "All", "None"). These are ignored for mapping.
#>

[CmdletBinding()]
param(
  [Parameter()]
  [string]$OutFile = (Join-Path -Path (Get-Location) -ChildPath "entra-conditional-access.json"),

  [Parameter()]
  [ValidateSet("v1.0","beta")]
  [string]$GraphProfile = "v1.0",

  [Parameter()]
  [int]$JsonDepth = 80,

  [Parameter()]
  [switch]$IncludeDirectoryObjectMappings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Required module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
  }
}

function Get-UniqueGuidsFromIds {
  param([Parameter(Mandatory)]$Ids)

  $out = New-Object System.Collections.Generic.List[Guid]
  foreach ($id in $Ids) {
    if ($null -eq $id) { continue }
    $s = [string]$id
    $g = [Guid]::Empty
    if ([Guid]::TryParse($s, [ref]$g)) {
      $out.Add($g) | Out-Null
    }
  }
  return $out | Sort-Object -Unique
}

function Add-Ids {
  param(
    [Parameter(Mandatory)][ref]$Target,
    [Parameter()]$Values
  )
  if ($null -eq $Values) { return }
  $Target.Value += @($Values)
}

function Resolve-WithError {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][scriptblock]$Resolver,
    [Parameter(Mandatory)][scriptblock]$OnSuccess,
    [Parameter(Mandatory)][scriptblock]$OnError
  )

  try {
    $obj = & $Resolver
    & $OnSuccess $obj
  }
  catch {
    & $OnError $_
  }
}

# Modules
# (These module names match the official Graph PowerShell SDK pattern. If you installed the meta-module
#  "Microsoft.Graph", these will still be available as submodules.)
Ensure-Module -Name "Microsoft.Graph.Authentication"
Ensure-Module -Name "Microsoft.Graph.Identity.SignIns"
Ensure-Module -Name "Microsoft.Graph.Users"
Ensure-Module -Name "Microsoft.Graph.Groups"
Ensure-Module -Name "Microsoft.Graph.Applications"
Ensure-Module -Name "Microsoft.Graph.DirectoryObjects"
Ensure-Module -Name "Microsoft.Graph.Identity.DirectoryManagement"

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop
Import-Module Microsoft.Graph.Applications -ErrorAction Stop
Import-Module Microsoft.Graph.DirectoryObjects -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

Write-Host "Connecting to Microsoft Graph ($GraphProfile) with interactive sign-in..."
Select-MgProfile -Name $GraphProfile

# Delegated permissions needed.
# Note: Some of these scopes typically require admin consent in the tenant.
$scopes = @(
  "Policy.Read.All",
  "User.Read.All",
  "Group.Read.All",
  "Application.Read.All",
  "Directory.Read.All"
)

Connect-MgGraph -Scopes $scopes | Out-Null

try {
  $ctx = Get-MgContext
  Write-Host "Connected. TenantId=$($ctx.TenantId) Account=$($ctx.Account)"

  Write-Host "Fetching Conditional Access policies..."
  $policies = Get-MgIdentityConditionalAccessPolicy -All

  $mappings = $null

  if ($IncludeDirectoryObjectMappings.IsPresent) {
    Write-Host "Collecting referenced IDs from policy conditions..."

    # Raw ID collections (may contain GUIDs and non-GUID tokens like 'All')
    $includeUsers = @();  $excludeUsers = @()
    $includeGroups = @(); $excludeGroups = @()
    $includeApps = @();   $excludeApps = @()
    $includeLocations = @(); $excludeLocations = @()
    $authContextRefs = @()
    $includeRoles = @();  $excludeRoles = @()

    foreach ($p in $policies) {
      $c = $p.Conditions
      if ($null -eq $c) { continue }

      # Users/Groups/Roles
      $u = $c.Users
      if ($null -ne $u) {
        Add-Ids ([ref]$includeUsers)  $u.IncludeUsers
        Add-Ids ([ref]$excludeUsers)  $u.ExcludeUsers
        Add-Ids ([ref]$includeGroups) $u.IncludeGroups
        Add-Ids ([ref]$excludeGroups) $u.ExcludeGroups

        # Role collections exist in many tenants (includeRoles/excludeRoles)
        # If not present, these will be $null and safely ignored.
        Add-Ids ([ref]$includeRoles) $u.IncludeRoles
        Add-Ids ([ref]$excludeRoles) $u.ExcludeRoles
      }

      # Applications
      $a = $c.Applications
      if ($null -ne $a) {
        Add-Ids ([ref]$includeApps) $a.IncludeApplications
        Add-Ids ([ref]$excludeApps) $a.ExcludeApplications
        # includeUserActions is not GUIDs; ignore for mapping
      }

      # Locations
      $l = $c.Locations
      if ($null -ne $l) {
        Add-Ids ([ref]$includeLocations) $l.IncludeLocations
        Add-Ids ([ref]$excludeLocations) $l.ExcludeLocations
      }

      # Authentication contexts: model varies; we keep best-effort.
      # Many tenants expose this under conditions.authenticationContextClassReferences or similar.
      # We'll attempt to capture common shapes.
      if ($null -ne $c.AuthenticationContexts) {
        Add-Ids ([ref]$authContextRefs) $c.AuthenticationContexts
      }
      if ($null -ne $c.AuthenticationContextClassReferences) {
        Add-Ids ([ref]$authContextRefs) $c.AuthenticationContextClassReferences
      }
    }

    # Convert raw lists to unique GUID strings only
    $userIds  = @(Get-UniqueGuidsFromIds -Ids (@($includeUsers + $excludeUsers)) | ForEach-Object { $_.Guid })
    $groupIds = @(Get-UniqueGuidsFromIds -Ids (@($includeGroups + $excludeGroups)) | ForEach-Object { $_.Guid })
    $appLikeIds = @(Get-UniqueGuidsFromIds -Ids (@($includeApps + $excludeApps)) | ForEach-Object { $_.Guid })
    $locationIds = @(Get-UniqueGuidsFromIds -Ids (@($includeLocations + $excludeLocations)) | ForEach-Object { $_.Guid })
    $authContextIds = @(Get-UniqueGuidsFromIds -Ids ($authContextRefs) | ForEach-Object { $_.Guid })
    $roleIds = @(Get-UniqueGuidsFromIds -Ids (@($includeRoles + $excludeRoles)) | ForEach-Object { $_.Guid })

    # Maps we’ll emit
    $userMap  = [ordered]@{}
    $groupMap = [ordered]@{}
    $applicationMap = [ordered]@{}       # application object id -> {displayName, appId}
    $servicePrincipalMap = [ordered]@{}  # servicePrincipal object id -> {displayName, appId}
    $namedLocationMap = [ordered]@{}     # namedLocation id -> {displayName, odataType}
    $authContextMap = [ordered]@{}       # auth context id -> {displayName}
    $roleMap = [ordered]@{}              # directoryRole / roleTemplate id -> {displayName, description?}

    # USERS
    if ($userIds.Count -gt 0) {
      Write-Host "Resolving $($userIds.Count) user GUID(s)..."
      foreach ($id in $userIds) {
        Resolve-WithError -Id $id `
          -Resolver { Get-MgUser -UserId $id -Property "id,displayName,userPrincipalName" -ErrorAction Stop } `
          -OnSuccess {
            param($user)
            $userMap[$user.Id] = [ordered]@{
              displayName = $user.DisplayName
              userPrincipalName = $user.UserPrincipalName
            }
          } `
          -OnError {
            param($e)
            $userMap[$id] = [ordered]@{
              displayName = $null
              userPrincipalName = $null
              error = $e.Exception.Message
            }
          }
      }
    }

    # GROUPS
    if ($groupIds.Count -gt 0) {
      Write-Host "Resolving $($groupIds.Count) group GUID(s)..."
      foreach ($id in $groupIds) {
        Resolve-WithError -Id $id `
          -Resolver { Get-MgGroup -GroupId $id -Property "id,displayName" -ErrorAction Stop } `
          -OnSuccess {
            param($group)
            $groupMap[$group.Id] = [ordered]@{ displayName = $group.DisplayName }
          } `
          -OnError {
            param($e)
            $groupMap[$id] = [ordered]@{ displayName = $null; error = $e.Exception.Message }
          }
      }
    }

    # APPLICATIONS / SERVICE PRINCIPALS
    # CA includes/excludes often reference service principal object IDs, but can vary.
    # We'll attempt ServicePrincipal first, then Application.
    if ($appLikeIds.Count -gt 0) {
      Write-Host "Resolving $($appLikeIds.Count) application/servicePrincipal GUID(s)..."
      foreach ($id in $appLikeIds) {
        $resolved = $false

        # Try Service Principal
        try {
          $sp = Get-MgServicePrincipal -ServicePrincipalId $id -Property "id,displayName,appId" -ErrorAction Stop
          $servicePrincipalMap[$sp.Id] = [ordered]@{ displayName = $sp.DisplayName; appId = $sp.AppId }
          $resolved = $true
        } catch {}

        # Try Application object
        if (-not $resolved) {
          try {
            $app = Get-MgApplication -ApplicationId $id -Property "id,displayName,appId" -ErrorAction Stop
            $applicationMap[$app.Id] = [ordered]@{ displayName = $app.DisplayName; appId = $app.AppId }
            $resolved = $true
          } catch {
            # Store as service principal bucket with error (it's more commonly what CA stores)
            $servicePrincipalMap[$id] = [ordered]@{ displayName = $null; appId = $null; error = $_.Exception.Message }
          }
        }
      }
    }

    # NAMED LOCATIONS (Conditional Access Named Locations)
    if ($locationIds.Count -gt 0) {
      Write-Host "Resolving $($locationIds.Count) named location GUID(s)..."
      foreach ($id in $locationIds) {
        try {
          $nl = Get-MgIdentityConditionalAccessNamedLocation -ConditionalAccessNamedLocationId $id -ErrorAction Stop

          $odataType = $null
          try { $odataType = $nl.AdditionalProperties.'@odata.type' } catch {}

          $namedLocationMap[$nl.Id] = [ordered]@{
            displayName = $nl.DisplayName
            odataType   = $odataType
          }
        } catch {
          $namedLocationMap[$id] = [ordered]@{
            displayName = $null
            error = $_.Exception.Message
          }
        }
      }
    }

    # AUTHENTICATION CONTEXTS (best-effort; cmdlet availability can vary by module/version/profile)
    if ($authContextIds.Count -gt 0) {
      Write-Host "Resolving $($authContextIds.Count) authentication context GUID(s) (best-effort)..."
      foreach ($id in $authContextIds) {
        try {
          # This cmdlet exists in many Graph SDK versions; if not, it will throw and we'll record the error.
          $ac = Get-MgIdentityConditionalAccessAuthenticationContextClassReference -AuthenticationContextClassReferenceId $id -ErrorAction Stop
          $authContextMap[$ac.Id] = [ordered]@{ displayName = $ac.DisplayName }
        } catch {
          $authContextMap[$id] = [ordered]@{ displayName = $null; error = $_.Exception.Message }
        }
      }
    }

    # ROLES (best-effort)
    # Depending on tenant/API, CA may reference directory role IDs or role template IDs.
    # We'll attempt two approaches:
    #  1) Resolve as DirectoryRole (activated role instance)
    #  2) Resolve as DirectoryRoleTemplate
    if ($roleIds.Count -gt 0) {
      Write-Host "Resolving $($roleIds.Count) role GUID(s) (best-effort)..."
      foreach ($id in $roleIds) {
        $resolved = $false

        try {
          $dr = Get-MgDirectoryRole -DirectoryRoleId $id -Property "id,displayName,description" -ErrorAction Stop
          $roleMap[$dr.Id] = [ordered]@{ displayName = $dr.DisplayName; description = $dr.Description }
          $resolved = $true
        } catch {}

        if (-not $resolved) {
          try {
            $tmpl = Get-MgDirectoryRoleTemplate -DirectoryRoleTemplateId $id -Property "id,displayName,description" -ErrorAction Stop
            $roleMap[$tmpl.Id] = [ordered]@{ displayName = $tmpl.DisplayName; description = $tmpl.Description }
            $resolved = $true
          } catch {
            $roleMap[$id] = [ordered]@{ displayName = $null; error = $_.Exception.Message }
          }
        }
      }
    }

    $mappings = [ordered]@{
      users = $userMap
      groups = $groupMap
      applications = $applicationMap
      servicePrincipals = $servicePrincipalMap
      namedLocations = $namedLocationMap
      authenticationContexts = $authContextMap
      roles = $roleMap
    }
  }

  $export = [ordered]@{
    exportedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    graphProfile  = $GraphProfile
    tenantId      = $ctx.TenantId
    account       = $ctx.Account
    policyCount   = @($policies).Count
    policies      = $policies
    directoryObjectMappings = $mappings
  }

  $json = $export | ConvertTo-Json -Depth $JsonDepth

  $outDir = Split-Path -Parent $OutFile
  if ($outDir -and -not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
  }

  $json | Set-Content -Path $OutFile -Encoding UTF8

  Write-Host "Done. Wrote $(@($policies).Count) policies to: $OutFile"
  if ($IncludeDirectoryObjectMappings.IsPresent) {
    Write-Host "Included directory object mappings in output (users, groups, apps/SPs, locations, auth contexts, roles - best effort)."
  }
}
finally {
  Disconnect-MgGraph | Out-Null
}
