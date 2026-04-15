<#
.SYNOPSIS
  Exports Microsoft Entra Conditional Access policies to JSON via Microsoft Graph PowerShell (Beta API).

.DESCRIPTION
  Uses the Microsoft Graph Beta API to capture the full policy state and all condition objects
  (users, applications, clientAppTypes, locations, deviceStates, platforms, signInRiskLevels, etc.).
  Writes a single aggregate JSON file with export metadata. All internal primitive arrays are sorted
  before serialization for consistent, diff-friendly output. Microsoft-managed policies are included.

  Optionally performs GUID -> display name enrichment for objects referenced in policy conditions.
  Optionally exports individual per-policy JSON files (duplicate DisplayName handled automatically).
  Optionally writes a structured log file with timestamps.

.NOTES
  - Requires Microsoft Graph PowerShell SDK v2+ (uses Get-MgBeta* cmdlets).
  - Mapping resolution is best-effort and will never fail the export.
  - Non-GUID tokens in CA policy collections (e.g. "All", "None") are ignored for mapping.
  - Microsoft-managed policies (isSystemManaged = true) are included via -All.
#>

[CmdletBinding()]
param(
  [Parameter()]
  [string]$OutFile,

  [Parameter()]
  [string]$LogFile,

  [Parameter()]
  # Depth 10 accommodates Beta CA policy nesting (conditions > sub-conditions ~5-6 levels); increase if truncation occurs.
  [int]$JsonDepth = 10,

  [Parameter()]
  [switch]$IncludeDirectoryObjectMappings,

  [Parameter()]
  [switch]$ExportIndividualPolicies,

  [Parameter()]
  [string]$IndividualPoliciesDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet("INFO","WARN","ERROR")]
    [string]$Level = "INFO"
  )
  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $line = "[$timestamp] [$Level] $Message"
  Write-Host $line
  if ($LogFile) {
    $line | Add-Content -Path $LogFile -Encoding UTF8
  }
}

function Assert-RequiredModule {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Version]$MinimumVersion
  )
  $available = @(Get-Module -ListAvailable -Name $Name)
  if ($available.Count -eq 0) {
    throw "Required module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
  }
  if ($MinimumVersion) {
    $highest = ($available | Sort-Object Version -Descending | Select-Object -First 1).Version
    if ($highest -lt $MinimumVersion) {
      throw "Module '$Name' is installed (v$highest) but v$MinimumVersion or later is required. Upgrade with: Update-Module $Name"
    }
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
    $obj = Invoke-MgWithRetry -ScriptBlock $Resolver
    & $OnSuccess $obj
  }
  catch {
    & $OnError $_
  }
}

# Wraps a Graph SDK scriptblock with retry logic for HTTP 429 (throttling) responses.
# Retries up to $MaxRetries times with exponential back-off. All other errors are re-thrown.
function Invoke-MgWithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [int]$MaxRetries = 3,
    [int]$BaseDelaySeconds = 5
  )
  $attempt = 0
  while ($true) {
    try {
      return (& $ScriptBlock)
    } catch {
      $attempt++
      $isThrottle = ($_.Exception.Message -match '429|Too Many Requests|throttl') -or
                    ($null -ne $_.Exception.Response -and
                     $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::TooManyRequests)
      if (-not $isThrottle -or $attempt -gt $MaxRetries) { throw }
      $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
      Write-Log "Graph API throttled (attempt $attempt/$MaxRetries). Retrying in ${delay}s..." -Level WARN
      Start-Sleep -Seconds $delay
    }
  }
}

# Recursively converts Graph SDK objects to ordered hashtables, sorting primitive arrays for
# consistent, diff-friendly JSON output. Object property order is preserved.
# Script-level flag so the depth-cap warning is emitted at most once per run.
$script:_depthWarningEmitted = $false
function ConvertTo-SortedObject {
  param($InputObject, [int]$Depth = 0)

  # Cap recursion at 20 (well above the practical ~6 levels of Beta CA policy objects) to guard against
  # unexpected circular or extremely deep structures in future API changes.
  if ($Depth -gt 20) {
    if (-not $script:_depthWarningEmitted) {
      Write-Log "Object serialization depth exceeded 20 levels; deeper properties are omitted. Consider raising -JsonDepth if output appears truncated." -Level WARN
      $script:_depthWarningEmitted = $true
    }
    return $null
  }
  if ($null -eq $InputObject) { return $null }

  # Primitives: return as-is
  if ($InputObject -is [string] -or $InputObject -is [bool] -or
      $InputObject -is [int] -or $InputObject -is [long] -or
      $InputObject -is [double] -or $InputObject -is [Enum] -or
      $InputObject -is [datetime]) {
    return $InputObject
  }

  # Arrays and lists: recurse, then sort if all items are primitive
  if ($InputObject.GetType().IsArray -or $InputObject -is [System.Collections.IList]) {
    $items = @($InputObject | ForEach-Object { ConvertTo-SortedObject $_ ($Depth + 1) })
    if ($items.Count -gt 1 -and $null -ne $items[0] -and
        ($items[0] -is [string] -or $items[0] -is [int] -or $items[0] -is [long])) {
      return @($items | Sort-Object)
    }
    return $items
  }

  # Dictionaries: preserve key order, recurse into values
  if ($InputObject -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
      $result[$key] = ConvertTo-SortedObject $InputObject[$key] ($Depth + 1)
    }
    return $result
  }

  # PSCustomObject / typed SDK objects: convert to ordered hashtable
  $result = [ordered]@{}
  $props = try {
    @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty','Property' })
  } catch { @() }
  foreach ($prop in $props) {
    try {
      $result[$prop.Name] = ConvertTo-SortedObject $prop.Value ($Depth + 1)
    } catch {
      $result[$prop.Name] = $null
    }
  }
  return $result
}

# Returns a filesystem-safe filename, appending the policy ID when DisplayName is duplicated.
function Get-SafeFileName {
  param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$PolicyId,
    [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$UsedNames
  )
  $safe = $DisplayName -replace '[\\/:*?"<>|]', '_'
  # Strip leading/trailing whitespace and periods (periods cause issues on some filesystems)
  $safe = $safe.Trim(' .')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "policy" }

  # Avoid reserved Windows device names (CON, NUL, PRN, AUX, COM0-COM9, LPT0-LPT9).
  # Use case-insensitive match because Windows treats these names case-insensitively.
  if ($safe -imatch '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
    $safe = "${safe}_policy"
  }

  $candidate = $safe
  if ($UsedNames.Contains($candidate.ToLowerInvariant())) {
    $candidate = "${safe}_${PolicyId}"
  }

  $UsedNames.Add($candidate.ToLowerInvariant()) | Out-Null
  return "${candidate}.json"
}

# Modules
# Beta cmdlets for CA policies require Microsoft.Graph.Beta.Identity.SignIns (SDK v2+).
# User/group/app resolution uses stable v1.0 cmdlets which remain available alongside beta.
Assert-RequiredModule -Name "Microsoft.Graph.Authentication"               -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.Beta.Identity.SignIns"        -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.Users"                        -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.Groups"                       -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.Applications"                 -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.DirectoryObjects"             -MinimumVersion "2.0"
Assert-RequiredModule -Name "Microsoft.Graph.Identity.DirectoryManagement" -MinimumVersion "2.0"

Import-Module Microsoft.Graph.Authentication          -ErrorAction Stop
Import-Module Microsoft.Graph.Beta.Identity.SignIns   -ErrorAction Stop
Import-Module Microsoft.Graph.Users                   -ErrorAction Stop
Import-Module Microsoft.Graph.Groups                  -ErrorAction Stop
Import-Module Microsoft.Graph.Applications            -ErrorAction Stop
Import-Module Microsoft.Graph.DirectoryObjects        -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

# Initialise log file directory if needed
if ($LogFile) {
  $logDir = Split-Path -Parent $LogFile
  if ($logDir -and -not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
  }
}

# Resolve default paths at runtime so they reflect the working directory when the script
# actually runs, not when parameters were bound (which could differ in interactive sessions).
if (-not $OutFile) {
  $OutFile = Join-Path -Path (Get-Location) -ChildPath "entra-conditional-access.json"
}
if (-not $IndividualPoliciesDir) {
  $IndividualPoliciesDir = Join-Path -Path (Get-Location) -ChildPath "policies"
}

Write-Log "Connecting to Microsoft Graph (Beta) with interactive sign-in..."

# Disconnect any existing Graph session to avoid silently reusing a stale token or a
# wrong-tenant context from a previous connection in the same PowerShell session.
$_existingCtx = Get-MgContext
if ($null -ne $_existingCtx) {
  Write-Log "Existing Graph session found (TenantId=$([string]$_existingCtx.TenantId) Account=$([string]$_existingCtx.Account)). Disconnecting before reconnecting..." -Level WARN
  Disconnect-MgGraph | Out-Null
}

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
  if ($null -eq $ctx) { throw "Get-MgContext returned null after Connect-MgGraph. Authentication may have failed." }
  Write-Log "Connected. TenantId=$([string]$ctx.TenantId) Account=$([string]$ctx.Account)"

  # Verify that all required scopes were actually granted. Admin consent may be withheld for
  # some scopes, causing a silent partial connection that fails later with a 403.
  $grantedScopes = @($ctx.Scopes)
  $missingScopes = @($scopes | Where-Object { $grantedScopes -notcontains $_ })
  if ($missingScopes.Count -gt 0) {
    throw "The following required scopes were not granted: $($missingScopes -join ', '). " +
          "Ensure admin consent has been granted in the tenant and re-run the script."
  }

  Write-Log "Fetching Conditional Access policies via Beta API (includes Microsoft-managed policies)..."
  $policies = Get-MgBetaIdentityConditionalAccessPolicy -All

  # Sort policies by DisplayName for consistent, diff-friendly output
  $policies = @($policies | Sort-Object -Property DisplayName)

  Write-Log "Retrieved $(@($policies).Count) policies."

  $mappings = $null

  if ($IncludeDirectoryObjectMappings.IsPresent) {
    Write-Log "Collecting referenced IDs from policy conditions..."

    # Raw ID collections (may contain GUIDs and non-GUID tokens like 'All')
    $includeUsers = @();     $excludeUsers = @()
    $includeGroups = @();    $excludeGroups = @()
    $includeApps = @();      $excludeApps = @()
    $includeLocations = @(); $excludeLocations = @()
    $authContextRefs = @()
    $includeRoles = @();     $excludeRoles = @()

    foreach ($p in $policies) {
      $c = $p.Conditions
      if ($null -eq $c) { continue }

      # Users / Groups / Roles
      $u = $c.Users
      if ($null -ne $u) {
        Add-Ids ([ref]$includeUsers)  $u.IncludeUsers
        Add-Ids ([ref]$excludeUsers)  $u.ExcludeUsers
        Add-Ids ([ref]$includeGroups) $u.IncludeGroups
        Add-Ids ([ref]$excludeGroups) $u.ExcludeGroups
        Add-Ids ([ref]$includeRoles)  $u.IncludeRoles
        Add-Ids ([ref]$excludeRoles)  $u.ExcludeRoles
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

      # Authentication contexts (model varies; best-effort)
      if ($null -ne $c.AuthenticationContexts) {
        Add-Ids ([ref]$authContextRefs) $c.AuthenticationContexts
      }
      if ($null -ne $c.AuthenticationContextClassReferences) {
        Add-Ids ([ref]$authContextRefs) $c.AuthenticationContextClassReferences
      }
    }

    # Convert raw lists to unique GUID strings only
    $userIds        = @(Get-UniqueGuidsFromIds -Ids (@($includeUsers + $excludeUsers))         | ForEach-Object { $_.Guid })
    $groupIds       = @(Get-UniqueGuidsFromIds -Ids (@($includeGroups + $excludeGroups))       | ForEach-Object { $_.Guid })
    $appLikeIds     = @(Get-UniqueGuidsFromIds -Ids (@($includeApps + $excludeApps))           | ForEach-Object { $_.Guid })
    $locationIds    = @(Get-UniqueGuidsFromIds -Ids (@($includeLocations + $excludeLocations)) | ForEach-Object { $_.Guid })
    $authContextIds = @(Get-UniqueGuidsFromIds -Ids ($authContextRefs)                         | ForEach-Object { $_.Guid })
    $roleIds        = @(Get-UniqueGuidsFromIds -Ids (@($includeRoles + $excludeRoles))         | ForEach-Object { $_.Guid })

    # Maps we'll emit
    $userMap             = [ordered]@{}  # user object id -> {displayName, userPrincipalName}
    $groupMap            = [ordered]@{}  # group object id -> {displayName}
    $applicationMap      = [ordered]@{}  # application object id -> {displayName, appId}
    $servicePrincipalMap = [ordered]@{}  # servicePrincipal object id -> {displayName, appId}
    $namedLocationMap    = [ordered]@{}  # namedLocation id -> {displayName, odataType}
    $authContextMap      = [ordered]@{}  # auth context id -> {displayName}
    $roleMap             = [ordered]@{}  # directoryRole / roleTemplate id -> {displayName, description}

    # USERS
    if ($userIds.Count -gt 0) {
      Write-Log "Resolving $($userIds.Count) user GUID(s)..."
      foreach ($id in $userIds) {
        Resolve-WithError -Id $id `
          -Resolver { Get-MgUser -UserId $id -Property "id,displayName,userPrincipalName" -ErrorAction Stop } `
          -OnSuccess {
            param($user)
            $userMap[$user.Id] = [ordered]@{
              displayName       = $user.DisplayName
              userPrincipalName = $user.UserPrincipalName
            }
          } `
          -OnError {
            param($e)
            $userMap[$id] = [ordered]@{
              displayName       = $null
              userPrincipalName = $null
              error             = $e.Exception.Message
            }
          }
      }
    }

    # GROUPS
    if ($groupIds.Count -gt 0) {
      Write-Log "Resolving $($groupIds.Count) group GUID(s)..."
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
      Write-Log "Resolving $($appLikeIds.Count) application/servicePrincipal GUID(s)..."
      foreach ($id in $appLikeIds) {
        $resolved = $false

        # Try Service Principal
        try {
          $sp = Invoke-MgWithRetry -ScriptBlock {
            Get-MgServicePrincipal -ServicePrincipalId $id -Property "id,displayName,appId" -ErrorAction Stop
          }
          $servicePrincipalMap[$sp.Id] = [ordered]@{ displayName = $sp.DisplayName; appId = $sp.AppId }
          $resolved = $true
        } catch {
          Write-Log "  ServicePrincipal lookup failed for $id (will try Application): $($_.Exception.Message)" -Level WARN
        }

        # Try Application object
        if (-not $resolved) {
          try {
            $app = Invoke-MgWithRetry -ScriptBlock {
              Get-MgApplication -ApplicationId $id -Property "id,displayName,appId" -ErrorAction Stop
            }
            $applicationMap[$app.Id] = [ordered]@{ displayName = $app.DisplayName; appId = $app.AppId }
            $resolved = $true
          } catch {
            # Store as service principal bucket with error (it's more commonly what CA stores)
            $servicePrincipalMap[$id] = [ordered]@{ displayName = $null; appId = $null; error = $_.Exception.Message }
          }
        }
      }
    }

    # NAMED LOCATIONS (via Beta API for full type information)
    if ($locationIds.Count -gt 0) {
      Write-Log "Resolving $($locationIds.Count) named location GUID(s)..."
      foreach ($id in $locationIds) {
        try {
          $nl = Get-MgBetaIdentityConditionalAccessNamedLocation -ConditionalAccessNamedLocationId $id -ErrorAction Stop

          $odataType = $null
          try { $odataType = $nl.AdditionalProperties.'@odata.type' } catch {}

          $namedLocationMap[$nl.Id] = [ordered]@{
            displayName = $nl.DisplayName
            odataType   = $odataType
          }
        } catch {
          $namedLocationMap[$id] = [ordered]@{
            displayName = $null
            error       = $_.Exception.Message
          }
        }
      }
    }

    # AUTHENTICATION CONTEXTS (best-effort; via Beta API)
    if ($authContextIds.Count -gt 0) {
      Write-Log "Resolving $($authContextIds.Count) authentication context GUID(s) (best-effort)..."
      foreach ($id in $authContextIds) {
        try {
          $ac = Get-MgBetaIdentityConditionalAccessAuthenticationContextClassReference `
            -AuthenticationContextClassReferenceId $id -ErrorAction Stop
          $authContextMap[$ac.Id] = [ordered]@{ displayName = $ac.DisplayName }
        } catch {
          $authContextMap[$id] = [ordered]@{ displayName = $null; error = $_.Exception.Message }
        }
      }
    }

    # ROLES (best-effort)
    # CA may reference directory role IDs or role template IDs depending on the tenant/API.
    # We'll attempt DirectoryRole first, then DirectoryRoleTemplate.
    if ($roleIds.Count -gt 0) {
      Write-Log "Resolving $($roleIds.Count) role GUID(s) (best-effort)..."
      foreach ($id in $roleIds) {
        $resolved = $false

        try {
          $dr = Invoke-MgWithRetry -ScriptBlock {
            Get-MgDirectoryRole -DirectoryRoleId $id -Property "id,displayName,description" -ErrorAction Stop
          }
          $roleMap[$dr.Id] = [ordered]@{ displayName = $dr.DisplayName; description = $dr.Description }
          $resolved = $true
        } catch {
          Write-Log "  DirectoryRole lookup failed for $id (will try DirectoryRoleTemplate): $($_.Exception.Message)" -Level WARN
        }

        if (-not $resolved) {
          try {
            $tmpl = Invoke-MgWithRetry -ScriptBlock {
              Get-MgDirectoryRoleTemplate -DirectoryRoleTemplateId $id -Property "id,displayName,description" -ErrorAction Stop
            }
            $roleMap[$tmpl.Id] = [ordered]@{ displayName = $tmpl.DisplayName; description = $tmpl.Description }
            $resolved = $true
          } catch {
            $roleMap[$id] = [ordered]@{ displayName = $null; error = $_.Exception.Message }
          }
        }
      }
    }

    $mappings = [ordered]@{
      users                  = $userMap
      groups                 = $groupMap
      applications           = $applicationMap
      servicePrincipals      = $servicePrincipalMap
      namedLocations         = $namedLocationMap
      authenticationContexts = $authContextMap
      roles                  = $roleMap
    }
  }

  # Convert policy objects to ordered hashtables with sorted primitive arrays
  Write-Log "Serializing $(@($policies).Count) policies (sorting internal arrays)..."
  $sortedPolicies = @($policies | ForEach-Object { ConvertTo-SortedObject $_ })

  $export = [ordered]@{
    exportedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
    graphApi                = "beta"
    tenantId                = $ctx.TenantId
    account                 = $ctx.Account
    policyCount             = @($policies).Count
    policies                = $sortedPolicies
    directoryObjectMappings = $mappings
  }

  $json = $export | ConvertTo-Json -Depth $JsonDepth

  $outDir = Split-Path -Parent $OutFile
  if ($outDir -and -not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
  }

  if (Test-Path -Path $OutFile) {
    Write-Log "Output file already exists and will be overwritten: $OutFile" -Level WARN
  }
  $json | Set-Content -Path $OutFile -Encoding UTF8
  Write-Log "Wrote aggregate JSON ($(@($policies).Count) policies) to: $OutFile"

  if ($IncludeDirectoryObjectMappings.IsPresent) {
    Write-Log "Included directory object mappings (users, groups, apps/SPs, locations, auth contexts, roles - best effort)."
  }

  # Export individual per-policy JSON files (optional)
  if ($ExportIndividualPolicies.IsPresent) {
    Write-Log "Exporting individual policy files to: $IndividualPoliciesDir"
    if (-not (Test-Path -Path $IndividualPoliciesDir)) {
      New-Item -ItemType Directory -Path $IndividualPoliciesDir | Out-Null
    }

    $usedNames = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($p in $sortedPolicies) {
      # ConvertTo-SortedObject preserves PascalCase property names from the Graph SDK objects.
      # The camelCase fallbacks (displayName, id) guard against future SDK serialization changes.
      $displayName = if ($p.DisplayName) { $p.DisplayName } elseif ($p.displayName) { $p.displayName } else { "unknown" }
      $policyId    = if ($p.Id)          { $p.Id }          elseif ($p.id)          { $p.id }          else { [Guid]::NewGuid().ToString() }

      $fileName = Get-SafeFileName -DisplayName $displayName -PolicyId $policyId -UsedNames $usedNames
      $filePath = Join-Path -Path $IndividualPoliciesDir -ChildPath $fileName
      $p | ConvertTo-Json -Depth $JsonDepth | Set-Content -Path $filePath -Encoding UTF8
      Write-Log "  Written: $fileName"
    }
    Write-Log "Individual policy export complete ($($sortedPolicies.Count) files)."
  }
}
finally {
  try {
    Disconnect-MgGraph | Out-Null
    Write-Log "Disconnected from Microsoft Graph."
  } catch {
    Write-Log "Note: Disconnect-MgGraph raised an error (session may not have been established): $($_.Exception.Message)" -Level WARN
  }
}
