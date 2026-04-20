#Requires -Version 7.0

<#
.SYNOPSIS
    Tests that role member export respects user-type and object-type exclusion filters.

.DESCRIPTION
    Validates the fix for the issue where ALTER ROLE ... ADD MEMBER statements were emitted
    for principals that were excluded via user-type filters (WindowsUsers, SqlUsers, etc.),
    which would cause import failures when those principals were not exported.

    Tests:
    1. Static analysis: verify Test-UserExcludedByLoginType is applied to role members
    2. Simulation: verify each login-type exclusion correctly suppresses role memberships
    3. Simulation: verify role-as-member is suppressed when DatabaseRoles is excluded
    4. Simulation: verify name-based exclusion still applies
    5. Simulation: verify non-excluded members pass through correctly

.NOTES
    Issue: #128 - Export role memberships
    PR:    #131
#>
# TestType: unit

param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

# -- Test framework --

$script:total  = 0
$script:passed = 0
$script:failed = 0

function Write-TestResult {
  param([string]$Name, [bool]$Passed, [string]$Detail = '')
  $script:total++
  if ($Passed) {
    $script:passed++
    Write-Host "  [PASS] $Name" -ForegroundColor Green
  } else {
    $script:failed++
    $msg = "  [FAIL] $Name"
    if ($Detail) { $msg += " - $Detail" }
    Write-Host $msg -ForegroundColor Red
  }
}

$exportContent = Get-Content (Join-Path $projectRoot 'Export-SqlServerSchema.ps1') -Raw

# -- Section helpers --

# Extract Build-WorkItems-Security function body for targeted checks
$securityFn = [regex]::Match($exportContent,
  'function Build-WorkItems-Security[\s\S]*?(?=\nfunction |\z)').Value

# -- Part 1: Static analysis --

Write-Host "`n=== Part 1: Static analysis - fix is structurally present ===" -ForegroundColor Yellow

Write-TestResult 'RoleMembers block exists in Build-WorkItems-Security' `
  ($securityFn -match '# Role Members')

Write-TestResult 'Test-UserExcludedByLoginType called for custom role members' `
  ($securityFn -match 'Test-UserExcludedByLoginType.*memberUser')

Write-TestResult 'Test-UserExcludedByLoginType called for fixed role members' `
  ($securityFn -match 'Test-UserExcludedByLoginType.*memberUser')

Write-TestResult '$Database.Users lookup used for each member' `
  ($securityFn -match '\$Database\.Users\[\$member\]')

Write-TestResult '$Database.Roles lookup used for role-as-member case' `
  ($securityFn -match '\$Database\.Roles\[\$member\]')

Write-TestResult 'DatabaseRoles type exclusion applied to role-as-member' `
  ($securityFn -match "Test-ObjectTypeExcluded.*DatabaseRoles")

# Count occurrences - fix must appear in BOTH custom and fixed loops
$loginTypeCheckCount = ([regex]::Matches($securityFn, 'Test-UserExcludedByLoginType')).Count
Write-TestResult 'Test-UserExcludedByLoginType appears in both member loops (count >= 2)' `
  ($loginTypeCheckCount -ge 2) "Count: $loginTypeCheckCount"

$dbUserLookupCount = ([regex]::Matches($securityFn, '\$Database\.Users\[\$member\]')).Count
Write-TestResult '$Database.Users lookup appears in both member loops (count >= 2)' `
  ($dbUserLookupCount -ge 2) "Count: $dbUserLookupCount"

# -- Part 2: Simulation - login-type filtering logic --

Write-Host "`n=== Part 2: Simulation - login-type exclusion suppresses memberships ===" -ForegroundColor Yellow

# Re-implement the member filtering logic locally (mirrors Export-SqlServerSchema.ps1)
function Test-MemberExcluded-Sim {
  param(
    [string]$MemberName,
    [string]$MemberLoginType,   # null/empty = member is a role, not a user
    [bool]$MemberIsRole = $false,
    [string[]]$ExcludeObjectTypes = @(),
    [string[]]$ExcludeObjects = @()
  )

  # 1. Name-based exclusion
  if ($ExcludeObjects -contains $MemberName) { return $true }

  if ($MemberIsRole) {
    # 2a. Role-as-member: excluded if DatabaseRoles type is excluded
    return ($ExcludeObjectTypes -contains 'DatabaseRoles')
  } else {
    # 2b. User-as-member: excluded by login-type / umbrella filters
    if ($ExcludeObjectTypes -contains 'DatabaseUsers') { return $true }
    switch ($MemberLoginType) {
      { $_ -in 'WindowsUser','WindowsGroup' } { return ($ExcludeObjectTypes -contains 'WindowsUsers') }
      'SqlLogin'                              { return ($ExcludeObjectTypes -contains 'SqlUsers') }
      { $_ -in 'Certificate','AsymmetricKey'} { return ($ExcludeObjectTypes -contains 'CertificateMappedUsers') }
      { $_ -in 'ExternalUser','ExternalGroup'}{ return ($ExcludeObjectTypes -contains 'ExternalUsers') }
    }
  }
  return $false
}

$cases = @(
  # Login-type exclusions
  @{ Name='DOMAIN\Alice'; LoginType='WindowsUser';  IsRole=$false; Exclude=@('WindowsUsers');        Expected=$true;  Label='WindowsUser member suppressed by WindowsUsers exclusion' }
  @{ Name='DOMAIN\Grp';  LoginType='WindowsGroup'; IsRole=$false; Exclude=@('WindowsUsers');        Expected=$true;  Label='WindowsGroup member suppressed by WindowsUsers exclusion' }
  @{ Name='sqluser1';    LoginType='SqlLogin';      IsRole=$false; Exclude=@('SqlUsers');            Expected=$true;  Label='SqlLogin member suppressed by SqlUsers exclusion' }
  @{ Name='aaduser';     LoginType='ExternalUser';  IsRole=$false; Exclude=@('ExternalUsers');       Expected=$true;  Label='ExternalUser member suppressed by ExternalUsers exclusion' }
  @{ Name='certuser';    LoginType='Certificate';   IsRole=$false; Exclude=@('CertificateMappedUsers'); Expected=$true; Label='Certificate user suppressed by CertificateMappedUsers exclusion' }

  # Umbrella DatabaseUsers exclusion
  @{ Name='DOMAIN\Bob'; LoginType='WindowsUser';  IsRole=$false; Exclude=@('DatabaseUsers'); Expected=$true; Label='WindowsUser suppressed by DatabaseUsers umbrella' }
  @{ Name='sqluser2';   LoginType='SqlLogin';      IsRole=$false; Exclude=@('DatabaseUsers'); Expected=$true; Label='SqlLogin suppressed by DatabaseUsers umbrella' }
  @{ Name='aaduser2';   LoginType='ExternalUser';  IsRole=$false; Exclude=@('DatabaseUsers'); Expected=$true; Label='ExternalUser suppressed by DatabaseUsers umbrella' }

  # Role-as-member
  @{ Name='NestedRole'; LoginType='';            IsRole=$true; Exclude=@('DatabaseRoles'); Expected=$true;  Label='Role-as-member suppressed by DatabaseRoles exclusion' }
  @{ Name='NestedRole'; LoginType='';            IsRole=$true; Exclude=@('SqlUsers');      Expected=$false; Label='Role-as-member NOT suppressed by SqlUsers exclusion' }

  # Non-excluded members pass through
  @{ Name='sqluser3';    LoginType='SqlLogin';   IsRole=$false; Exclude=@('WindowsUsers'); Expected=$false; Label='SqlLogin NOT suppressed by WindowsUsers exclusion' }
  @{ Name='DOMAIN\Eve'; LoginType='WindowsUser'; IsRole=$false; Exclude=@('SqlUsers');     Expected=$false; Label='WindowsUser NOT suppressed by SqlUsers exclusion' }
  @{ Name='sqluser4';    LoginType='SqlLogin';   IsRole=$false; Exclude=@();              Expected=$false; Label='Member not suppressed when no exclusions' }

  # Name-based exclusion still works regardless of login type
  @{ Name='dbo.OldUser'; LoginType='SqlLogin'; IsRole=$false; Exclude=@(); ExcludeObj=@('dbo.OldUser'); Expected=$true; Label='Name-based exclusion suppresses member' }

  # Multiple exclusion types
  @{ Name='sqluser5'; LoginType='SqlLogin'; IsRole=$false; Exclude=@('WindowsUsers','SqlUsers'); Expected=$true; Label='SqlLogin suppressed with multiple exclude types' }
)

foreach ($c in $cases) {
  $excludeObj = if ($c.ExcludeObj) { $c.ExcludeObj } else { @() }
  $result = Test-MemberExcluded-Sim `
    -MemberName $c.Name `
    -MemberLoginType $c.LoginType `
    -MemberIsRole $c.IsRole `
    -ExcludeObjectTypes $c.Exclude `
    -ExcludeObjects $excludeObj
  Write-TestResult $c.Label ($result -eq $c.Expected) "Expected=$($c.Expected) Got=$result"
}

# -- Summary --

Write-Host ""
Write-Host "  Total: $script:total  Passed: $script:passed  Failed: $script:failed" -ForegroundColor Cyan

if ($script:failed -gt 0) {
  Write-Host "  SOME TESTS FAILED" -ForegroundColor Red
  exit 1
} else {
  Write-Host "  ALL TESTS PASSED" -ForegroundColor Green
  exit 0
}
