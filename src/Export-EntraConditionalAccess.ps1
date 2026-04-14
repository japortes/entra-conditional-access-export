<#
.SYNOPSIS
  Exports Microsoft Entra Conditional Access policies to JSON via Microsoft Graph PowerShell.
.DESCRIPTION
  Uses interactive sign-in (delegated permissions). Writes a JSON file containing CA policies.
  Additionally collects directory object displayName mappings for referenced users and groups.

  Output file defaults to entra-conditional-access.json.
#>

[CmdletBinding()]
param(
  [Parameter()]
  [string]$OutFile = (Join-Path -Path (Get-Location) -ChildPath "entra-conditional-access.json"),

  [Parameter()]
  [ValidateSet("v1.0","beta")]
  [string]$GraphProfile = "v1.0",

  [Parameter()]
  [int]$JsonDepth = 50,

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
    # Graph ids are typically strings; accept GUID strings only
    $s = [string]$id
    $g = [Guid]::Empty
    if ([Guid]::TryParse($s, [ref]$g)) {
      $out.Add($g) | Out-Null
    }
  }
  # unique
  return $out | Sort-Object -Unique
}

# Modules
Ensure-Module -Name "Microsoft.Graph.Authentication"
Ensure-Module -Name "Microsoft.Graph.Identity.SignIns"
Ensure-Module -Name "Microsoft.Graph.Users"
Ensure-Module -Name "Microsoft.Graph.Groups"

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

Write-Host "Connecting to Microsoft Graph ($GraphProfile) with interactive sign-in..."
Select-MgProfile -Name $GraphProfile

# Delegated permission needed for CA policies (admin consent typically required)
$scopes = @(
  "Policy.Read.All",
  "User.Read.All",
  "Group.Read.All"
)

Connect-MgGraph -Scopes $scopes | Out-Null

try {
  $ctx = Get-MgContext
  Write-Host "Connected. TenantId=$($ctx.TenantId) Account=$($ctx.Account)"

  Write-Host "Fetching Conditional Access policies..."
  $policies = Get-MgIdentityConditionalAccessPolicy -All

  $mappings = $null
  if ($IncludeDirectoryObjectMappings.IsPresent) {
    Write-Host "Collecting referenced user/group GUIDs from policy conditions..."

    $includeUsers = @()
    $excludeUsers = @()
    $includeGroups = @()
    $excludeGroups = @()

    foreach ($p in $policies) {
      $u = $p.Conditions.Users
      if ($null -eq $u) { continue }

      # Users can contain includeUsers/excludeUsers, includeGroups/excludeGroups.
      $includeUsers += @($u.IncludeUsers)
      $excludeUsers += @($u.ExcludeUsers)
      $includeGroups += @($u.IncludeGroups)
      $excludeGroups += @($u.ExcludeGroups)
    }

    $userGuids = Get-UniqueGuidsFromIds -Ids (@($includeUsers + $excludeUsers))
    $groupGuids = Get-UniqueGuidsFromIds -Ids (@($includeGroups + $excludeGroups))

    $userMap = [ordered]@{}
    $groupMap = [ordered]@{}

    if ($userGuids.Count -gt 0) {
      Write-Host "Resolving $($userGuids.Count) user GUID(s) to displayName/userPrincipalName..."
      foreach ($g in $userGuids) {
        try {
          $user = Get-MgUser -UserId $g.Guid -Property "id,displayName,userPrincipalName" -ErrorAction Stop
          $userMap[$user.Id] = [ordered]@{
            displayName = $user.DisplayName
            userPrincipalName = $user.UserPrincipalName
          }
        }
        catch {
          # Keep placeholders so consumers know it was referenced but not resolvable
          $userMap[$g.Guid] = [ordered]@{
            displayName = $null
            userPrincipalName = $null
            error = $_.Exception.Message
          }
        }
      }
    }

    if ($groupGuids.Count -gt 0) {
      Write-Host "Resolving $($groupGuids.Count) group GUID(s) to displayName..."
      foreach ($g in $groupGuids) {
        try {
          $group = Get-MgGroup -GroupId $g.Guid -Property "id,displayName" -ErrorAction Stop
          $groupMap[$group.Id] = [ordered]@{
            displayName = $group.DisplayName
          }
        }
        catch {
          $groupMap[$g.Guid] = [ordered]@{
            displayName = $null
            error = $_.Exception.Message
          }
        }
      }
    }

    $mappings = [ordered]@{
      users = $userMap
      groups = $groupMap
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
    Write-Host "Included directory object mappings (users/groups) in output."
  }
}
finally {
  Disconnect-MgGraph | Out-Null
}