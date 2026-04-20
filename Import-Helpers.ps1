#Requires -Version 7.0

<#
.SYNOPSIS
    Import filter helper functions used by Import-SqlServerSchema.ps1.

.DESCRIPTION
    This file is dot-sourced by Import-SqlServerSchema.ps1 at startup. It contains pure
    filter functions that determine whether a script file should be excluded from import
    based on schema, object name, or object type criteria, plus configuration helpers
    for import-time option resolution.

    Functions provided:
      - Test-SchemaExcluded          : Checks if a script belongs to an excluded schema
      - Test-ObjectExcluded          : Checks if a script matches an excluded object pattern
      - Test-ScriptExcluded          : Checks if a script should be excluded by object type
      - Get-DatabaseOptionExclusions : Returns database option names to skip during import

    This file has no param() block and no mandatory parameters, making it safe to dot-source.

.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema
    Issue: #113 - Extract import filter functions into dot-sourceable helper
           #129 - Add Get-DatabaseOptionExclusions for per-option import control
#>

# ─────────────────────────────────────────────────────────────────────────────
# Test-SchemaExcluded
# ─────────────────────────────────────────────────────────────────────────────

function Test-SchemaExcluded {
  <#
    .SYNOPSIS
        Checks if a script file belongs to an excluded schema.
    .DESCRIPTION
        Extracts schema from filename patterns like 'Schema.ObjectName.sql' or
        'Schema.ObjectName.type.sql' and checks against excluded schemas list.
        Only applies to schema-bound object folders (Tables, Views, Functions, etc.)
        to avoid false positives on users/roles/security objects.
    .PARAMETER ScriptPath
        Full path to the script file.
    .PARAMETER ExcludeSchemas
        Array of schema names to exclude.
    .OUTPUTS
        $true if script's schema is excluded, $false otherwise.
  #>
  param(
    [string]$ScriptPath,
    [string[]]$ExcludeSchemas
  )

  if (-not $ExcludeSchemas -or $ExcludeSchemas.Count -eq 0) {
    return $false
  }

  # Only apply schema filtering to folders containing schema-bound objects
  # This prevents false positives like user "cdc.user.sql" being treated as schema "cdc"
  # Note: Programmability has nested subfolders (02_Functions, 03_StoredProcedures, etc.)
  $schemaBoundFolders = @(
    'Tables',           # Matches 09_Tables_PrimaryKey, 11_Tables_ForeignKeys, etc.
    'Indexes',          # Matches 10_Indexes
    'Views',            # Matches 05_Views (nested under 14_Programmability)
    'Functions',        # Matches 02_Functions (nested under 14_Programmability)
    'StoredProcedures', # Matches 03_StoredProcedures (nested under 14_Programmability)
    'Triggers',         # Matches 04_Triggers (nested under 14_Programmability)
    'Synonyms',         # Matches 15_Synonyms
    'Sequences',        # Matches 04_Sequences
    'Types',            # Matches 07_Types
    'XmlSchemaCollections', # Matches 08_XmlSchemaCollections
    'Defaults',         # Matches 12_Defaults
    'Rules',            # Matches 13_Rules
    'Data'              # Matches 21_Data
  )

  # Extract folder name from path (immediate parent)
  $parentFolder = Split-Path (Split-Path $ScriptPath -Parent) -Leaf

  # Check if this is a schema-bound folder
  # Strip numeric prefix (e.g., '09_Tables_PrimaryKey' -> 'Tables_PrimaryKey')
  # then check for exact match or underscore-separated suffix (e.g., Tables, Tables_PrimaryKey)
  $folderBase = $parentFolder -replace '^\d+_', ''
  $isSchemaBoundFolder = $false
  foreach ($folder in $schemaBoundFolders) {
    if ($folderBase -eq $folder -or $folderBase -like "${folder}_*") {
      $isSchemaBoundFolder = $true
      break
    }
  }

  if (-not $isSchemaBoundFolder) {
    return $false  # Not a schema-bound folder, don't filter
  }

  $fileName = Split-Path $ScriptPath -Leaf

  # Pattern 1: Schema.ObjectName.sql or Schema.ObjectName.type.sql
  # Examples: cdc.fn_cdc_get_all_changes.function.sql, dbo.MyTable.sql
  if ($fileName -match '^([^.]+)\.') {
    $schemaName = $matches[1]

    # Skip numeric prefixes from grouped files (e.g., 001_dbo.sql -> extract dbo)
    if ($schemaName -match '^\d{3}_(.+)$') {
      $schemaName = $matches[1]
    }

    if ($ExcludeSchemas -contains $schemaName) {
      return $true
    }
  }

  return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-ObjectExcluded
# ─────────────────────────────────────────────────────────────────────────────

function Test-ObjectExcluded {
  <#
    .SYNOPSIS
        Checks if a script file matches an excluded object pattern.
    .DESCRIPTION
        Extracts schema.objectName from filename patterns like 'Schema.ObjectName.sql' or
        'Schema.ObjectName.type.sql' and checks against excluded object patterns using
        wildcard matching (-ilike). Only applies to schema-bound object folders.
  #>
  param(
    [string]$ScriptPath,
    [string[]]$ExcludeObjects
  )

  if (-not $ExcludeObjects -or $ExcludeObjects.Count -eq 0) {
    return $false
  }

  # Only apply object filtering to folders containing schema-bound objects
  $schemaBoundFolders = @(
    'Tables', 'Indexes', 'Views', 'Functions', 'StoredProcedures',
    'Triggers', 'Synonyms', 'Sequences', 'Types', 'XmlSchemaCollections',
    'Defaults', 'Rules', 'Data'
  )

  # Extract immediate parent folder name
  $parentFolder = Split-Path (Split-Path $ScriptPath -Parent) -Leaf

  # Strip numeric prefix and check for exact match or underscore-separated suffix
  $folderBase = $parentFolder -replace '^\d+_', ''
  $isSchemaBoundFolder = $false
  foreach ($folder in $schemaBoundFolders) {
    if ($folderBase -eq $folder -or $folderBase -like "${folder}_*") {
      $isSchemaBoundFolder = $true
      break
    }
  }

  if (-not $isSchemaBoundFolder) {
    return $false  # Not a schema-bound folder, don't filter
  }

  $fileName = Split-Path $ScriptPath -Leaf

  # Extract schema.objectName from filename patterns:
  # Schema.ObjectName.sql or Schema.ObjectName.type.sql
  # Handle numeric prefixes: 001_Schema.ObjectName.sql
  if ($fileName -match '^(?:\d{3}_)?([^.]+)\.([^.]+)') {
    $schemaName = $matches[1]
    $objectName = $matches[2]
    $qualifiedName = "$schemaName.$objectName"

    foreach ($pattern in $ExcludeObjects) {
      if ($qualifiedName -ilike $pattern) {
        return $true
      }
    }
  }

  return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-ScriptExcluded
# ─────────────────────────────────────────────────────────────────────────────

function Test-ScriptExcluded {
  <#
    .SYNOPSIS
        Checks if a script file should be excluded based on ExcludeObjectTypes settings.
    .DESCRIPTION
        Determines exclusion based on folder path and filename patterns.
        Supports granular user type exclusions (WindowsUsers, SqlUsers, etc.).
    .PARAMETER ScriptPath
        Full path to the script file.
    .PARAMETER ExcludeTypes
        Array of object types to exclude.
    .OUTPUTS
        $true if script should be excluded, $false otherwise.
  #>
  param(
    [string]$ScriptPath,
    [string[]]$ExcludeTypes
  )

  if (-not $ExcludeTypes -or $ExcludeTypes.Count -eq 0) {
    return $false
  }

  $fileName = Split-Path $ScriptPath -Leaf
  $relativePath = $ScriptPath

  # Build exclusion patterns based on ExcludeTypes
  foreach ($excludeType in $ExcludeTypes) {
    switch ($excludeType) {
      'FileGroups' {
        if ($relativePath -match '00_FileGroups') { return $true }
      }
      'DatabaseConfiguration' {
        if ($relativePath -match '02_DatabaseConfiguration') { return $true }
      }
      'Schemas' {
        if ($relativePath -match '03_Schemas') { return $true }
      }
      'Sequences' {
        if ($relativePath -match '04_Sequences') { return $true }
      }
      'PartitionFunctions' {
        if ($relativePath -match '05_PartitionFunctions') { return $true }
      }
      'PartitionSchemes' {
        if ($relativePath -match '06_PartitionSchemes') { return $true }
      }
      'Types' {
        if ($relativePath -match '07_Types') { return $true }
      }
      'XmlSchemaCollections' {
        if ($relativePath -match '08_XmlSchemaCollections') { return $true }
      }
      'Tables' {
        if ($relativePath -match '09_Tables|11_Tables') { return $true }
      }
      'ForeignKeys' {
        if ($relativePath -match '11_Tables.*ForeignKeys') { return $true }
      }
      'Indexes' {
        if ($relativePath -match '10_Indexes') { return $true }
      }
      'Defaults' {
        if ($relativePath -match '12_Defaults') { return $true }
      }
      'Rules' {
        if ($relativePath -match '13_Rules') { return $true }
      }
      'Programmability' {
        if ($relativePath -match '14_Programmability') { return $true }
      }
      'Views' {
        if ($relativePath -match '14_Programmability[\\/]05_Views') { return $true }
      }
      'Functions' {
        if ($relativePath -match '14_Programmability[\\/]02_Functions') { return $true }
      }
      'StoredProcedures' {
        if ($relativePath -match '14_Programmability[\\/]03_StoredProcedures') { return $true }
      }
      'Synonyms' {
        if ($relativePath -match '15_Synonyms') { return $true }
      }
      'SearchPropertyLists' {
        if ($relativePath -match '18_SearchPropertyLists') { return $true }
      }
      'PlanGuides' {
        if ($relativePath -match '19_PlanGuides') { return $true }
      }
      'DatabaseRoles' {
        # Exclude .role.sql files in 01_Security
        if ($relativePath -match '01_Security' -and $fileName -match '\.role\.sql$') { return $true }
      }
      'DatabaseUsers' {
        # Exclude ALL .user.sql files (umbrella exclusion)
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') { return $true }
      }
      'WindowsUsers' {
        # Exclude Windows domain user files based on file CONTENT (not filename pattern)
        # Detection patterns for Windows users:
        #   1. FOR LOGIN [DOMAIN\User] - explicit login mapping with backslash
        #   2. CREATE USER [DOMAIN\User] - implicit (username = login name, contains backslash)
        # Example filenames: "dbo.DOMAIN.TestUser.user.sql", "dbo.NT SERVICE.SQLSERVERAGENT.user.sql"
        # Windows principals: DOMAIN\User, NT SERVICE\name, NT AUTHORITY\SYSTEM, BUILTIN\Administrators
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content) {
            # Method 1: Check FOR LOGIN [name] for backslash
            if ($content -match 'FOR LOGIN\s*\[([^\]]+)\]') {
              $loginName = $matches[1]
              if ($loginName -match '\\') {
                return $true
              }
            }
            # Method 2: Check CREATE USER [name] for backslash (implicit Windows login)
            # This handles: CREATE USER [DOMAIN\User] WITH DEFAULT_SCHEMA=[dbo]
            if ($content -match 'CREATE USER\s*\[([^\]]+)\]') {
              $userName = $matches[1]
              # Windows users have backslash AND no "WITHOUT LOGIN" or "FROM EXTERNAL PROVIDER"
              if ($userName -match '\\' -and $content -notmatch 'WITHOUT LOGIN' -and $content -notmatch 'EXTERNAL PROVIDER') {
                return $true
              }
            }
          }
        }
      }
      'SqlUsers' {
        # Exclude SQL Server login mapped users based on file CONTENT
        # Detection: File contains "FOR LOGIN [username]" where login name has NO backslash
        #            and is NOT an external provider (Azure AD)
        # Also includes: "WITHOUT LOGIN" users (contained database users)
        # Example filenames: "dbo.AppUser.user.sql", "dbo.sa.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content) {
            # Check for explicit FOR LOGIN without backslash (SQL login)
            if ($content -match 'FOR LOGIN\s*\[([^\]]+)\]') {
              $loginName = $matches[1]
              # SQL logins: no backslash (not Windows), not external provider (not Azure AD)
              if ($loginName -notmatch '\\' -and $content -notmatch 'EXTERNAL PROVIDER') {
                return $true
              }
            }
            # WITHOUT LOGIN users are SQL type (contained database users)
            if ($content -match 'WITHOUT LOGIN') {
              return $true
            }
            # Implicit SQL login: CREATE USER [name] where name has no backslash
            # and no WITHOUT LOGIN, no EXTERNAL PROVIDER, no FOR LOGIN
            # This handles: CREATE USER [AppUser] WITH DEFAULT_SCHEMA=[dbo]
            if ($content -match 'CREATE USER\s*\[([^\]]+)\]') {
              $userName = $matches[1]
              if ($userName -notmatch '\\' -and $content -notmatch 'WITHOUT LOGIN' -and
                  $content -notmatch 'EXTERNAL PROVIDER' -and $content -notmatch 'FOR LOGIN') {
                return $true
              }
            }
          }
        }
      }
      'ExternalUsers' {
        # Exclude Azure AD / External provider users based on file CONTENT
        # Detection: File contains "EXTERNAL PROVIDER" or "FROM EXTERNAL PROVIDER"
        # Example filenames: "dbo.user@domain.com.user.sql", "dbo.AzureADGroup.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content -match 'EXTERNAL PROVIDER|FROM EXTERNAL PROVIDER') {
            return $true
          }
        }
      }
      'CertificateMappedUsers' {
        # Exclude certificate or asymmetric key mapped users based on file CONTENT
        # Detection: File contains "FOR CERTIFICATE" or "FOR ASYMMETRIC KEY"
        # Example filenames: "dbo.CertUser.user.sql", "dbo.KeyMappedUser.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content -match 'FOR CERTIFICATE|FOR ASYMMETRIC KEY') {
            return $true
          }
        }
      }
      'SecurityPolicies' {
        if ($relativePath -match '20_SecurityPolicies') { return $true }
      }
      'DatabaseOptions' {
        if ($relativePath -match '003_DatabaseOptions') { return $true }
      }
      'Data' {
        if ($relativePath -match '21_Data') { return $true }
      }
    }
  }

  return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-DatabaseOptionExclusions
# ─────────────────────────────────────────────────────────────────────────────

function Get-DatabaseOptionExclusions {
  <#
  .SYNOPSIS
      Returns the list of database option names to exclude when applying .option.sql files.
  .DESCRIPTION
      In Dev mode, RECOVERY is excluded by default to avoid unintended side effects on developer
      environments. In Prod mode, no options are excluded by default. The exclusion list can be
      overridden for either mode via config keys import.developerMode.databaseOptionExclusions
      or import.productionMode.databaseOptionExclusions.
  .PARAMETER Mode
      Import mode: 'Dev' or 'Prod'. Default: 'Dev'.
  .PARAMETER Config
      Config hashtable (parsed from YAML config file).
  .OUTPUTS
      Array of option name strings (file stems of .option.sql files) to skip.
  #>
  param(
    [string]$Mode = 'Dev',
    $Config = @{}
  )

  # Check for mode-specific config override
  $modeKey = if ($Mode -eq 'Dev') { 'developerMode' } else { 'productionMode' }
  $modeConfig = $null
  if ($Config.import -and $Config.import[$modeKey]) {
    $modeConfig = $Config.import[$modeKey]
  }

  if ($modeConfig -and $modeConfig.ContainsKey('databaseOptionExclusions')) {
    $exclusions = $modeConfig.databaseOptionExclusions
    if ($null -eq $exclusions) { return @() }
    return @($exclusions)
  }

  # Default exclusions per mode: Dev excludes RECOVERY, Prod excludes nothing
  if ($Mode -eq 'Dev') {
    return @('RECOVERY')
  }
  return @()
}
