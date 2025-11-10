# Export/Import Strategy & Recommendations

**Version**: 1.1.0  
**Released**: November 10, 2025  
**Status**: Production Ready

## Core Philosophy

**Export Everything, Import Selectively**

- **Export**: Capture complete database definition including all object types
- **Import**: Default to developer-friendly mode with opt-in for production features
- **Flexibility**: Support multiple deployment scenarios through switches

---

## Export Strategy: ALWAYS COMPREHENSIVE

### Always Export (No Exceptions)

All database objects should be exported by default to ensure complete schema capture:

1. **Schemas, Types, Tables, Indexes, Constraints** - Core structure
2. **Programmability** - Functions, procedures, views, triggers
3. **Security** - Roles, users, permissions, certificates, keys
4. **Full-Text** - Catalogs, stop lists, search properties
5. **Partitioning** - Partition functions and schemes
6. **Sequences** - Number generators
7. **Synonyms** - Object aliases
8. **FileGroups** - Physical storage layout (NEW)
9. **Database Scoped Configurations** - Performance settings (NEW)
10. **Database Scoped Credentials** - External resource access (NEW)
11. **External Data Sources** - PolyBase/Elastic Query connections (NEW)
12. **External File Formats** - Data file definitions (NEW)
13. **Security Policies** - Row-Level Security (NEW)
14. **Search Property Lists** - Custom full-text properties (NEW)
15. **Data** - When `-IncludeData` specified

### Export Format Conventions

#### Infrastructure Objects (Special Handling Required)
```
FileGroups/
  001_FileGroups.sql          # CREATE statements with parameterized paths
  001_FileGroups.metadata.json # JSON mapping: objects -> filegroups
```

#### Credential Objects (STRUCTURE ONLY - NO SECRETS EVER)
```
DatabaseScopedCredentials/
  AzureBlobCredential.sql     # Object definition with SECRET commented out
  _MANUAL_SETUP_REQUIRED.txt  # Instructions for manual secret configuration
```

**Example credential export:**
```sql
/* 
 * DATABASE SCOPED CREDENTIAL: AzureBlobCredential
 * 
 * WARNING: This credential requires a secret value.
 * Secrets are NEVER exported for security reasons.
 * 
 * To create this credential, you must manually execute:
 *   CREATE DATABASE SCOPED CREDENTIAL [AzureBlobCredential]
 *   WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
 *   SECRET = 'your_actual_secret_here';
 * 
 * This credential is required by:
 *   - External Data Source: AzureDataLake
 */

-- The following CREATE statement is commented out because it requires a secret:
-- CREATE DATABASE SCOPED CREDENTIAL [AzureBlobCredential]
-- WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
-- SECRET = '***REMOVED***';
```

#### Configuration Objects (Environment Notes)
```
DatabaseScopedConfigurations/
  001_Configurations.sql      # All settings exported
  001_Configurations.notes.txt # Environment-specific warnings
```

#### Export Summary Reports (NEW)
```
_EXPORT_SUMMARY.txt          # Complete list of all exported objects
_SECRETS_REQUIRED.txt        # List of objects requiring manual secret setup
```

**Example _SECRETS_REQUIRED.txt:**
```
═══════════════════════════════════════════════════════════════
OBJECTS REQUIRING MANUAL SECRET CONFIGURATION
═══════════════════════════════════════════════════════════════

The following objects were exported but require secrets to be 
configured manually. Secrets are NEVER exported for security.

DATABASE SCOPED CREDENTIALS (2 objects)
----------------------------------------
1. AzureBlobCredential
   - IDENTITY: SHARED ACCESS SIGNATURE
   - Required by: ExternalDataSources/AzureDataLake
   - File: DatabaseScopedCredentials/AzureBlobCredential.sql

2. AzureStorageCredential
   - IDENTITY: SHARED ACCESS SIGNATURE
   - Required by: ExternalDataSources/AzureBackup
   - File: DatabaseScopedCredentials/AzureStorageCredential.sql

CERTIFICATES WITH PRIVATE KEYS (1 object)
------------------------------------------
1. TDE_Certificate
   - Required by: Transparent Data Encryption
   - File: Security/002_Certificates.sql
   - Note: Export/import private key separately using BACKUP CERTIFICATE

═══════════════════════════════════════════════════════════════
IMPORTANT: After importing the database schema, you must manually
configure these secrets before the dependent objects will function.
═══════════════════════════════════════════════════════════════
```

---

## Import Strategy: DEVELOPER MODE BY DEFAULT

### Default Import Behavior (Developer Mode)

**Goal**: Simplify local development by excluding environment-specific complexity

**Developer mode is the DEFAULT** - no flag required. Use `-ImportMode Prod` for production imports.

#### Objects Imported with Modifications

| Object Type | Developer Mode Behavior | Production Mode Behavior | Override Switch |
|------------|-------------------------|--------------------------|-----------------|
| **FileGroups** | SKIP - Remap all objects to PRIMARY | IMPORT - Use config file paths | `-IncludeFileGroups` |
| **DatabaseScopedConfigurations** | SKIP - Use server defaults | IMPORT - Apply production settings | `-IncludeConfigurations` |
| **DatabaseScopedCredentials** | ALWAYS SKIP - Manual setup only | ALWAYS SKIP - Manual setup only | N/A - Never imported |
| **ExternalDataSources** | SKIP - External dependencies | IMPORT - Use config file URLs | `-IncludeExternalData` |
| **SecurityPolicies** | IMPORT but SET STATE=OFF | IMPORT and SET STATE=ON | `-EnableSecurityPolicies` |
| **Data** | SKIP unless `-IncludeData` | SKIP unless `-IncludeData` | `-IncludeData` (existing) |
| **SearchPropertyLists** | IMPORT | IMPORT | Always imported |
| **PlanGuides** | IMPORT (with warning) | IMPORT (with warning) | Always imported |
| **ExternalLibraries** | IMPORT | IMPORT | Always imported |
| **ExternalLanguages** | IMPORT | IMPORT | Always imported |

**Note**: Database Scoped Credentials are NEVER imported by the script in any mode. They require manual configuration with actual secrets after import completes.

**Rationale for Developer Mode Defaults:**
- **FileGroups skipped**: Developer laptops don't need complex storage layouts
- **Configurations skipped**: MAXDOP=8 on a 4-core laptop causes poor performance
- **External data skipped**: Developers may not have access to production Azure resources
- **RLS disabled**: Developers need to see all data for debugging/testing
- **Rare objects imported**: Harmless if unused, documents database capabilities

#### Objects Always Imported (No Exceptions)

- Schemas, Types, Tables (structure only)
- Indexes, Primary Keys, Foreign Keys
- Partition Functions & Schemes (logical structure)
- Functions, Procedures, Views, Triggers
- Synonyms, Full-Text Catalogs, Full-Text Stop Lists
- Sequences
- Database Roles & Users (structure, not credentials)
- Certificates & Keys (structure only, if present in export)
- SearchPropertyLists, PlanGuides (with warnings)
- ExternalLibraries, ExternalLanguages (if present)
- ExternalFileFormats (metadata only)

### Production Import Mode

Enable with: `-ImportMode Prod`

```powershell
# Full production deployment
.\Import-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -SourcePath ".\export\prod_MyDb_20251109" `
    -ProductionMode `
    -FileGroupPathMapping @{
        "FG_CURRENT"="E:\SQLData\Current"
        "FG_ARCHIVE"="F:\SQLArchive\Archive"
    }

# Or granular control
.\Import-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -SourcePath ".\export\prod_MyDb_20251109" `
    -IncludeFileGroups `
    -IncludeConfigurations `
    -EnableSecurityPolicies `
    -IncludeData

# NOTE: Credentials are NEVER imported by script
# After import completes, see _SECRETS_REQUIRED.txt for manual setup instructions
```

### Import Completion Report (NEW)

After import completes, the script displays a comprehensive summary:

**Console Output:**
```
═══════════════════════════════════════════════════════════════
IMPORT COMPLETED SUCCESSFULLY
═══════════════════════════════════════════════════════════════

Database: MyDb
Server: localhost
Import Date: 2025-11-09 14:30:00
Import Mode: Developer
Duration: 2m 34s

OBJECT TYPES IMPORTED
---------------------
✓ Schemas: 5
✓ Tables: 12
✓ Indexes: 8
✓ Foreign Keys: 4
✓ Stored Procedures: 6
✓ Views: 3
✓ Functions: 2
✓ Sequences: 1
✓ Synonyms: 2
✓ Security Policies: 2 (imported but DISABLED)

OBJECT TYPES NOT IMPORTED
--------------------------
[INFO] FileGroups: 3 objects
       Reason: Developer mode (objects remapped to PRIMARY)
       Action: Use -ImportMode Prod to import FileGroups

[INFO] Database Scoped Configurations: 5 settings
       Reason: Developer mode (using server defaults)
       Action: Use -ImportMode Prod or -IncludeConfigurations

[INFO] Database Scoped Credentials: 2 objects
       Reason: Credentials require manual setup (NEVER imported by script)
       Action: See MANUAL CONFIGURATION section below

[INFO] External Data Sources: 1 object
       Reason: Developer mode (external dependencies)
       Action: Use -ImportMode Prod or -IncludeExternalData

MANUAL CONFIGURATION REQUIRED
══════════════════════════════════════════════════════════════
The following objects were detected and require manual setup:

DATABASE SCOPED CREDENTIALS (2 detected)
-----------------------------------------
1. AzureBlobCredential
   See: DatabaseScopedCredentials/AzureBlobCredential.sql
   Required by: ExternalDataSources/AzureDataLake
   
2. AzureStorageCredential
   See: DatabaseScopedCredentials/AzureStorageCredential.sql
   Required by: ExternalDataSources/AzureBackup

CERTIFICATES WITH PRIVATE KEYS (0 detected)
--------------------------------------------
No certificates with private keys found. If your database uses
certificates for encryption or signing, you must export/import
them manually using BACKUP CERTIFICATE and CREATE CERTIFICATE.

ALWAYS ENCRYPTED KEYS (0 detected)
-----------------------------------
No Always Encrypted column master keys or encryption keys found.
If your database uses Always Encrypted, column master keys must
be configured in certificate stores before importing.

SECURITY POLICY NOTICE
----------------------
[WARNING] Row-Level Security policies were imported but DISABLED
          (STATE = OFF) for developer mode data visibility.
          
Actions:
• To enable RLS: Re-run import with -ImportMode Prod or -EnableSecurityPolicies
• To enable manually: See SecurityPolicies/*.sql and execute:
  ALTER SECURITY POLICY [PolicyName] WITH (STATE = ON);

NEXT STEPS
----------
1. If using credentials: Execute DatabaseScopedCredentials/*.sql with actual secrets
2. If RLS needed: Enable security policies (see above)
3. Test application connectivity and functionality

WARNING: External data sources will fail until credentials are configured.
══════════════════════════════════════════════════════════════

Import summary written to: _IMPORT_SUMMARY.txt
```

---

## Object-Specific Handling Recommendations

### 1. FileGroups & Physical Storage

**Export**: 
- Always export FileGroup definitions
- Generate metadata JSON mapping objects to FileGroups
- Use placeholder paths: `<DATA_PATH_PRIMARY>`, `<DATA_PATH_ARCHIVE>`

**Import**:
- **Developer Mode**: Skip FileGroups, remap all objects to PRIMARY
- **Production Mode**: 
  - Create FileGroups with user-supplied path mapping
  - Apply original object placements
  - Validate all referenced FileGroups exist

**Implementation**:
```powershell
# Export generates:
# FileGroups/001_FileGroups.sql
CREATE DATABASE FILEGROUP [FG_CURRENT];
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'CurrentData',
    FILENAME = N'<DATA_PATH_CURRENT>\current.ndf',
    SIZE = 1GB
) TO FILEGROUP [FG_CURRENT];

# FileGroups/001_FileGroups.metadata.json
{
  "filegroups": ["FG_CURRENT", "FG_ARCHIVE"],
  "objectMappings": {
    "dbo.Orders": "FG_CURRENT",
    "dbo.OrderHistory": "FG_ARCHIVE"
  }
}

# Import with -IncludeFileGroups requires:
-FileGroupPathMapping @{
    "FG_CURRENT"="E:\SQLData\Current"
    "FG_ARCHIVE"="F:\SQLArchive\Archive"
}
```

### 2. Database Scoped Configurations

**Export**: Always export all configurations

**Import**:
- **Developer Mode**: Skip entirely (use server defaults)
- **Production Mode**: Apply with warning prompt
  - Show configurations being applied
  - Require `-Confirm` or `-Force`

**Rationale**: MAXDOP, parallelism, cardinality estimation affect query behavior but may be hardware-specific

**Implementation**:
```powershell
# Export generates:
# DatabaseScopedConfigurations/001_Configurations.sql
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = OFF;
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SNIFFING = ON;

# Import behavior:
if (-not $IncludeConfigurations) {
    Write-Output "[INFO] Skipping Database Scoped Configurations (developer mode)"
    Write-Output "       Use -IncludeConfigurations to apply production settings"
} else {
    Write-Output "[WARNING] Applying Database Scoped Configurations"
    Write-Output "          Review settings - may be environment-specific:"
    # List configurations
    if (-not $Force) {
        $confirm = Read-Host "Apply these configurations? (Y/N)"
        if ($confirm -ne 'Y') { return }
    }
}
```

### 3. Database Scoped Credentials

**Export**: 
- Always export credential structure (commented out)
- Remove SECRET values entirely (show as ***REMOVED***)
- Generate _SECRETS_REQUIRED.txt summary report
- Generate instruction file

**Import**:
- **ALWAYS SKIP**: Credentials are never imported by script
- **Manual Setup Required**: User must execute credential creation statements manually after import with actual secrets
- Import completion report lists all credentials requiring setup

**Rationale**: Secrets cannot be safely extracted from SQL Server and should never be stored in source control or exported files

**Implementation**:
```powershell
# Export generates:
# DatabaseScopedCredentials/AzureBlobCredential.sql
-- ═════════════════════════════════════════════════════════════
-- DATABASE SCOPED CREDENTIAL: AzureBlobCredential
-- ═════════════════════════════════════════════════════════════
-- MANUAL CONFIGURATION REQUIRED
-- 
-- This credential requires a secret value that cannot be exported.
-- After importing the database, execute this statement with the
-- actual secret value:
--
-- CREATE DATABASE SCOPED CREDENTIAL [AzureBlobCredential]
-- WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
-- SECRET = '***REMOVED***';
--
-- Required by:
-- - ExternalDataSources/AzureDataLake
--
-- Documentation: Connect to prod-datalake.blob.core.windows.net
-- ═════════════════════════════════════════════════════════════

# Import behavior (ALWAYS):
Write-Output "[INFO] Skipping Database Scoped Credentials (manual setup required)"
Write-Output "       See DatabaseScopedCredentials/*.sql for instructions"
Write-Output "       All credential statements are commented out - execute manually with actual secrets"

# At end of import, _IMPORT_SUMMARY.txt includes:
MANUAL CONFIGURATION REQUIRED
══════════════════════════════════════════════════════════════
The following objects require secrets to be configured manually:

DATABASE SCOPED CREDENTIALS (2)
1. AzureBlobCredential
   See: DatabaseScopedCredentials/AzureBlobCredential.sql
   Required by: ExternalDataSources/AzureDataLake

2. AzureStorageCredential
   See: DatabaseScopedCredentials/AzureStorageCredential.sql
   Required by: ExternalDataSources/AzureBackup
```

### 4. External Data Sources & File Formats

**Export**: Always export with tokenized connection strings

**Import**:
- **Developer Mode**: Skip (no external dependencies)
- **Production Mode**: 
  - Require `-ExternalConnectionStrings` hashtable
  - Replace tokens with actual URLs

**Implementation**:
```powershell
# Export generates:
CREATE EXTERNAL DATA SOURCE [AzureDataLake]
WITH (
    TYPE = BLOB_STORAGE,
    LOCATION = '<EXTERNAL_URL_AzureDataLake>',
    CREDENTIAL = [AzureBlobCredential]
);

# Import:
-ExternalConnectionStrings @{
    "AzureDataLake" = "https://proddatalake.blob.core.windows.net/data"
}
```

### 5. Security Policies (Row-Level Security)

**Export**: Always export with STATE

**Import**:
- **Developer Mode**: Import but SET STATE = OFF
- **Production Mode**: Import and SET STATE = ON

**Rationale**: Developers need to see all data; production must enforce RLS

**Implementation**:
```powershell
# Export generates:
CREATE SECURITY POLICY [CustomerSecurityPolicy]
    ADD FILTER PREDICATE dbo.fn_SecurityPredicate(TenantId) ON dbo.Orders
WITH (STATE = ON);

# Import behavior:
if (-not $EnableSecurityPolicies) {
    # Modify script to SET STATE = OFF
    $sql = $sql -replace 'WITH \(STATE = ON\)', 'WITH (STATE = OFF)'
    Write-Output "[INFO] Security Policy imported but DISABLED (developer mode)"
} else {
    Write-Output "[SUCCESS] Security Policy imported and ENABLED"
}
```

### 6. Certificates & Asymmetric/Symmetric Keys

**Export**: Always export definitions

**Import**:
- **Developer Mode**: 
  - Import structure only
  - Cannot import actual key material without certificates
  - Document which objects depend on keys
- **Production Mode**: 
  - Require pre-installed certificates
  - Validate certificates exist before import
  - Provide detailed error messages

**Rationale**: Keys depend on server-level certificates that can't be scripted

**Implementation**:
```powershell
# Export generates warning:
# Security/002_Certificates.sql
/* WARNING: Certificate private keys cannot be exported via T-SQL
   This script creates certificate structure only.
   
   To import:
   1. Export certificate with private key from source:
      BACKUP CERTIFICATE MyCert TO FILE = 'MyCert.cer'
      WITH PRIVATE KEY (FILE = 'MyCert.key', ENCRYPTION BY PASSWORD = '...')
   
   2. Import on target before running this script:
      CREATE CERTIFICATE MyCert FROM FILE = 'MyCert.cer'
      WITH PRIVATE KEY (FILE = 'MyCert.key', DECRYPTION BY PASSWORD = '...')
*/

# Import behavior:
if (Test-CertificateExists 'MyCert') {
    # Apply script
} else {
    Write-Error "[ERROR] Certificate 'MyCert' not found. Import certificate first."
    Write-Output "       See Security/002_Certificates.sql for instructions"
}
```

### 7. Always Encrypted Objects

**Export**: Export structure with detailed warnings

**Import**:
- **Both Modes**: Skip by default
- Require `-IncludeAlwaysEncrypted` with pre-validation
- Display comprehensive setup instructions

**Rationale**: Always Encrypted requires client-side key stores and is extremely complex

### 8. Extended Stored Procedures

**Export**: Always export (already implemented)

**Import**: 
- **Both Modes**: Import normally
- Extended procs are often system utilities (xp_cmdshell, etc.)

### 9. Plan Guides

**Export**: Always export with warning comments

**Import**:
- **Developer Mode**: Skip (environment-specific)
- **Production Mode**: Import with warning

**Rationale**: Plan guides are typically created to work around specific production query plans

### 10. Full-Text Search Property Lists

**Export**: Always export

**Import**: 
- **Both Modes**: Import normally
- These are application logic, not environment config

---

## Proposed Parameter Structure

### Export Parameters
```powershell
.\Export-SqlServerSchema.ps1 `
    -Server <server> `
    -Database <database> `
    -OutputPath <path> `
    -TargetSqlVersion <version> `
    -IncludeData            # Export table data
    -Credential <cred>      # SQL authentication
    -ConfigFile <path>      # Optional: YAML config file
    
# Export always captures ALL objects by default
# Use config file to customize which objects to exclude
```

### Import Parameters
```powershell
.\Import-SqlServerSchema.ps1 `
    -Server <server> `
    -Database <database> `
    -SourcePath <path> `
    -Credential <cred> `
    
    # Existing parameters
    -CreateDatabase         # Create DB if not exists
    -Force                  # Skip schema existence check
    -ContinueOnError        # Continue on errors
    -IncludeData            # Load data
    
    # NEW: Import mode (developer is DEFAULT)
    -ImportMode <Dev|Prod>  # Dev = default, Prod = full production import
    
    # NEW: Optional overrides (command line overrides config file)
    -IncludeFileGroups      # Import FileGroups (Prod default: ON, Dev default: OFF)
    -IncludeConfigurations  # Import DB scoped configurations (Prod default: ON, Dev default: OFF)
    -IncludeExternalData    # Import external data sources (Prod default: ON, Dev default: OFF)
    -EnableSecurityPolicies # Enable RLS (Prod default: ON, Dev default: OFF)
    
    # Configuration file
    -ConfigFile <path>      # Optional: YAML config file for fine-grained control
    
    # NOTE: Credentials are NEVER imported - manual setup required
    
    # Production mode parameters
    -FileGroupPathMapping @{} # FileGroup path replacements
    -ExternalConnectionStrings @{} # External data source URLs
```

### Configuration File (YAML)

**File**: `export-import-config.yml`

```yaml
# Schema validation
$schema: "./export-import-config.schema.json"

# Export configuration
export:
  # Object types to exclude from export (all included by default)
  excludeObjectTypes:
    # - FileGroups
    # - DatabaseScopedConfigurations
    # - SecurityPolicies
  
  # Include data export
  includeData: false
  
  # Specific objects to exclude (by schema.name pattern)
  excludeObjects:
    # - "dbo.LegacyTable"
    # - "staging.*"

# Import configuration
import:
  # Default import mode (Dev or Prod)
  defaultMode: Dev
  
  # Developer mode overrides
  developerMode:
    includeFileGroups: false
    includeConfigurations: false
    includeDatabaseScopedCredentials: false  # Always false (manual setup)
    includeExternalData: false
    enableSecurityPolicies: false  # Import structure but set STATE=OFF
    includeData: false
    
    # Object types to exclude in dev mode
    excludeObjectTypes:
      # - PlanGuides
      # - ExternalLibraries
  
  # Production mode overrides
  productionMode:
    includeFileGroups: true
    includeConfigurations: true
    includeDatabaseScopedCredentials: false  # Always false (manual setup)
    includeExternalData: true
    enableSecurityPolicies: true  # Import and set STATE=ON
    includeData: false
    
    # FileGroup path mappings (environment-specific)
    fileGroupPathMapping:
      FG_CURRENT: "E:\\SQLData\\Current"
      FG_ARCHIVE: "F:\\SQLArchive\\Archive"
    
    # External data source URL replacements
    externalConnectionStrings:
      AzureDataLake: "https://proddatalake.blob.core.windows.net/data"
      AzureBackup: "https://prodbackup.blob.core.windows.net/backup"

# Note: Command-line parameters override config file settings
```

### YAML Schema

**File**: `export-import-config.schema.json`

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Export-SqlServerSchema Configuration",
  "description": "Configuration for SQL Server schema export and import operations",
  "type": "object",
  "properties": {
    "export": {
      "type": "object",
      "properties": {
        "excludeObjectTypes": {
          "type": "array",
          "items": {
            "type": "string",
            "enum": [
              "FileGroups",
              "DatabaseScopedConfigurations",
              "DatabaseScopedCredentials",
              "SecurityPolicies",
              "ExternalDataSources",
              "ExternalFileFormats",
              "SearchPropertyLists",
              "PlanGuides",
              "ExternalLibraries",
              "ExternalLanguages"
            ]
          },
          "description": "Object types to exclude from export"
        },
        "includeData": {
          "type": "boolean",
          "description": "Export table data as INSERT statements"
        },
        "excludeObjects": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Specific objects to exclude (supports wildcards)"
        }
      }
    },
    "import": {
      "type": "object",
      "properties": {
        "defaultMode": {
          "type": "string",
          "enum": ["Dev", "Prod"],
          "description": "Default import mode (Dev or Prod)"
        },
        "developerMode": {
          "$ref": "#/definitions/importSettings"
        },
        "productionMode": {
          "$ref": "#/definitions/importSettings"
        }
      }
    }
  },
  "definitions": {
    "importSettings": {
      "type": "object",
      "properties": {
        "includeFileGroups": { "type": "boolean" },
        "includeConfigurations": { "type": "boolean" },
        "includeDatabaseScopedCredentials": { 
          "type": "boolean",
          "const": false,
          "description": "Always false - credentials require manual setup"
        },
        "includeExternalData": { "type": "boolean" },
        "enableSecurityPolicies": { "type": "boolean" },
        "includeData": { "type": "boolean" },
        "excludeObjectTypes": {
          "type": "array",
          "items": { "type": "string" }
        },
        "fileGroupPathMapping": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        },
        "externalConnectionStrings": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        }
      }
    }
  }
}
```

### Script Startup Output

When scripts run, they display active configuration:

**Export Example:**
```
═══════════════════════════════════════════════════════════════
Export-SqlServerSchema v2.0
═══════════════════════════════════════════════════════════════
Server: localhost
Database: TestDb
Output: D:\exports\localhost_TestDb_20251109_143000

CONFIGURATION
-------------
Config File: export-import-config.yml
Include Data: No
Excluded Object Types: None

EXPORT SETTINGS (from config file)
-----------------------------------
✓ All object types included
✓ No specific objects excluded
✓ Data export: Disabled

═══════════════════════════════════════════════════════════════
Starting export...
```

**Import Example (Developer Mode - Default):**
```
═══════════════════════════════════════════════════════════════
Import-SqlServerSchema v2.0
═══════════════════════════════════════════════════════════════
Server: localhost
Database: MyDb_Dev
Source: D:\exports\localhost_TestDb_20251109_143000

CONFIGURATION
-------------
Import Mode: Developer (DEFAULT)
Config File: None (using defaults)
Command-line Overrides: None

IMPORT SETTINGS (Developer Mode)
---------------------------------
✓ FileGroups: SKIP (remap to PRIMARY)
✓ DatabaseScopedConfigurations: SKIP (use server defaults)
✓ DatabaseScopedCredentials: SKIP (manual setup required)
✓ ExternalDataSources: SKIP (external dependencies)
✓ SecurityPolicies: IMPORT but DISABLED (set STATE=OFF)
✓ Data: SKIP (use -IncludeData to import)

═══════════════════════════════════════════════════════════════
Starting import...
```

**Import Example (Production Mode):**
```
═══════════════════════════════════════════════════════════════
Import-SqlServerSchema v2.0
═══════════════════════════════════════════════════════════════
Server: prodserver
Database: MyDb
Source: D:\exports\localhost_TestDb_20251109_143000

CONFIGURATION
-------------
Import Mode: Production (specified via -ImportMode Prod)
Config File: export-import-config.yml
Command-line Overrides: -EnableSecurityPolicies

IMPORT SETTINGS (Production Mode)
---------------------------------
✓ FileGroups: IMPORT (paths from config file)
  - FG_CURRENT → E:\SQLData\Current
  - FG_ARCHIVE → F:\SQLArchive\Archive
✓ DatabaseScopedConfigurations: IMPORT (production settings)
✓ DatabaseScopedCredentials: SKIP (manual setup required)
✓ ExternalDataSources: IMPORT (URLs from config file)
  - AzureDataLake → https://proddatalake.blob.core.windows.net/data
✓ SecurityPolicies: IMPORT and ENABLED (STATE=ON) [OVERRIDE]
✓ Data: SKIP (use -IncludeData to import)

═══════════════════════════════════════════════════════════════
Starting import...
```

### Usage Examples

#### Developer Scenario (Default)
```powershell
# Simplest usage - developer mode is default, no flags needed
.\Import-SqlServerSchema.ps1 `
    -Server localhost `
    -Database MyDb_Dev `
    -SourcePath ".\exports\prod_MyDb_20251109" `
    -CreateDatabase `
    -IncludeData

# Result:
# - All logical objects imported
# - All objects on PRIMARY filegroup
# - No configurations applied (server defaults)
# - RLS policies imported but DISABLED (STATE=OFF)
# - No external dependencies
# - Completion report shows credentials requiring manual setup
```

#### Production Scenario (Using Config File)
```powershell
# Production deployment with config file
.\Import-SqlServerSchema.ps1 `
    -Server prodserver `
    -Database MyDb `
    -SourcePath ".\exports\prod_MyDb_20251109" `
    -ImportMode Prod `
    -ConfigFile ".\prod-config.yml" `
    -IncludeData

# Config file (prod-config.yml) contains:
# - FileGroup path mappings
# - External data source URLs
# - Production mode defaults

# Result:
# - Complete database recreation with production settings
# - FileGroups created at specified paths
# - Configurations applied
# - External data sources connected
# - RLS policies enabled
# - Completion report lists credentials requiring manual setup
```

#### Production Scenario (Command-line Parameters)
```powershell
# Production deployment without config file
.\Import-SqlServerSchema.ps1 `
    -Server prodserver `
    -Database MyDb `
    -SourcePath ".\exports\prod_MyDb_20251109" `
    -ImportMode Prod `
    -FileGroupPathMapping @{
        "FG_CURRENT" = "E:\SQLData\Current"
        "FG_ARCHIVE" = "F:\SQLArchive\Archive"
    } `
    -ExternalConnectionStrings @{
        "AzureDataLake" = "https://proddatalake.blob.core.windows.net"
    } `
    -IncludeData

# Result:
# - Same as above but using command-line parameters instead of config file
```

#### CI/CD Scenario (Selective Overrides)
```powershell
# Test environment: developer mode base + selective production features
.\Import-SqlServerSchema.ps1 `
    -Server testserver `
    -Database MyDb_Test `
    -SourcePath ".\exports\prod_MyDb_20251109" `
    -CreateDatabase `
    -IncludeConfigurations `      # Match prod query behavior
    -EnableSecurityPolicies `     # Test RLS logic
    -IncludeData `
    -ConfigFile ".\test-config.yml"  # Contains test external URLs

# Result:
# - Developer mode base (no FileGroups, remapped to PRIMARY)
# - Production configurations applied (MAXDOP, optimizer settings)
# - RLS enabled for integration testing
# - External data sources point to test resources
# - Completion report shows what was imported/skipped
```

#### Developer with Config File
```powershell
# Use config file to exclude specific object types
.\Import-SqlServerSchema.ps1 `
    -Server localhost `
    -Database MyDb_Dev `
    -SourcePath ".\exports\prod_MyDb_20251109" `
    -ConfigFile ".\dev-config.yml" `
    -IncludeData

# dev-config.yml excludes:
# - PlanGuides (environment-specific)
# - ExternalLibraries (don't need ML features locally)

# Result:
# - Standard developer mode
# - Config file fine-tunes what gets excluded
# - Cleaner local database without unused features
```

---

## Implementation Priority

### Phase 1: Core Infrastructure & Configuration System
1. **YAML Configuration File Support**
   - Schema definition (export-import-config.schema.json)
   - Parser/validator in both scripts
   - Command-line override logic
   - Default config file generation

2. **Startup Configuration Display**
   - Show active import mode (Dev/Prod)
   - Display config file settings
   - List command-line overrides
   - Preview what will be imported/skipped

3. **FileGroups Export & Import**
   - Export FileGroup definitions with metadata JSON
   - Import with path parameterization
   - Developer mode: auto-remap to PRIMARY
   - Production mode: create FileGroups from config

### Phase 2: New Object Types Export
4. **Database Scoped Configurations** - Export all settings with warnings
5. **Database Scoped Credentials** - Export structure only (commented out)
6. **Security Policies** - Export with STATE control
7. **External Data Sources** - Export with tokenized URLs
8. **External File Formats** - Export metadata
9. **Search Property Lists** - Export for full-text search
10. **Plan Guides** - Export with environment-specific warnings
11. **Rare Objects** - ExternalLibraries, ExternalLanguages (if present)

### Phase 3: Import Mode Logic
12. **Import Mode Framework** - `-ImportMode Dev|Prod` parameter
13. **Developer Mode Defaults** - Skip FileGroups, Configs, External
14. **Production Mode Defaults** - Import all with config file mappings
15. **Selective Overrides** - Individual switches override mode defaults
16. **Security Policy State Control** - Enable/disable RLS based on mode

### Phase 4: Completion Reporting
17. **Object Type Summaries** - Count what was imported/skipped
18. **Skipped Objects Report** - Explain why and how to override
19. **Manual Configuration Detection** - Scan for credentials, certificates, encryption keys
20. **RLS Status Notice** - Report security policy state with instructions
21. **Export Summary Report** - _SECRETS_REQUIRED.txt generation
22. **Import Summary Report** - _IMPORT_SUMMARY.txt with all details

### Phase 5: Polish & Testing
23. **Error Messages** - Clear explanations for failures
24. **Config File Validation** - Schema enforcement with helpful errors
25. **Integration Tests** - Test all modes with config files
26. **Documentation** - README updates with complete examples
27. **Sample Config Files** - Templates for dev/test/prod scenarios

### Phase 6: Integration Testing (COMPLETED)
28. **Update test-schema.sql** - Add sample objects for all new object types:
    - FileGroups (2-3 filegroups: PRIMARY, SECONDARY, ARCHIVE)
    - Database Scoped Configurations (MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING)
    - Database Scoped Credentials (1-2 credentials with commented-out secrets)
    - Security Policies (Row-Level Security with filter predicates)
    - Search Property Lists (custom full-text search properties)
    - Plan Guides (query hint examples)
    - Synonyms (additional examples)
    
    **Exclude from test database** (difficult to setup or container incompatible):
    - External Data Sources (requires Azure/external resources)
    - External File Formats (depends on External Data Sources)
    - External Libraries (requires ML Services configuration)
    - External Languages (requires custom language runtime setup)
    - Always Encrypted objects (requires certificate store configuration)
    - Certificates with private keys (complex key management)

29. **Enhanced Integration Test Script** - run-integration-test.ps1 validates:
    - **Export**: All new object types exported correctly with SQLCMD variables
    - **Dev Mode Import**: Infrastructure skipped, schema-only deployment works
    - **Prod Mode Import**: Full import with FileGroups, MAXDOP, Security Policies
    - **Cross-Platform Support**: Linux target server with correct path separators
    - **Data Integrity**: Row counts match across all modes, FK validation passes
    - **Database-Specific Naming**: Physical file names prevent conflicts

30. **Test Results (November 10, 2025)** - ALL TESTS PASSED:
    ```
    Export Phase:
    - 26 SQL files exported with FileGroups using $(FG_*_PATH_FILE) variables
    - All new object types (DB Config, Security Policies, etc.) exported
    
    Dev Mode (TestDb_Dev):
    - 23 scripts executed (3 infrastructure folders skipped)
    - 0 FileGroups (correctly skipped)
    - 0 Security Policies (infrastructure skipped)
    - 5 Customers + 6 Products imported (data integrity verified)
    
    Prod Mode (TestDb_Prod):
    - 26 scripts executed (full import)
    - 2 FileGroups created: FG_ARCHIVE, FG_CURRENT
    - Physical files: TestDb_Prod_TestDb_Archive.ndf, TestDb_Prod_TestDb_Current.ndf
    - 1 Security Policy imported
    - MAXDOP = 4 (database scoped configuration applied)
    - 5 Customers + 6 Products imported (data integrity verified)
    - Foreign keys validated successfully
    
    Cross-Platform Validation:
    - Target: Ubuntu 22.04 (Linux)
    - SQLCMD variables: /var/opt/mssql/data/ paths with / separator
    - Database-specific file naming prevents conflicts
    ```

31. **Bug Fixed During Phase 6**:
    - **Issue**: Prod mode was skipping FileGroups despite `importMode: Prod` in config
    - **Root Cause**: Import-YamlConfig was adding empty nested structure to simplified configs
    - **Solution**: Removed automatic structure addition, implemented three-tier fallback:
      1. Full config (nested import.productionMode structure)
      2. Simplified config (root-level importMode property)
      3. Hardcoded defaults (no config file)
    - **Result**: Both config formats now work correctly

---

## Project Status (November 10, 2025)

### COMPLETED: All Phases (1-6)

**Phase 1-4 Implementation**: Complete YAML configuration system, 10+ new object types, two-mode import system (Dev/Prod), and comprehensive completion summaries.

**Phase 5 Testing**: Successful export/import validation for both Dev and Prod modes with all new features working correctly.

**Phase 6 Integration Testing**: Full end-to-end validation with dual-mode testing, cross-platform FileGroups support, and comprehensive test coverage.

### Production-Ready Features

✅ **Export**: Complete schema capture with 21 folder types including all new object types  
✅ **Import Modes**: Two-mode system (Dev/Prod) with intelligent defaults and selective overrides  
✅ **YAML Configuration**: Full and simplified config formats with JSON Schema validation  
✅ **FileGroups**: Cross-platform support with SQLCMD variable parameterization  
✅ **Database-Specific Naming**: Prevents conflicts when deploying to multiple databases on same server  
✅ **Security Policies**: Row-Level Security with state control (enabled/disabled per mode)  
✅ **Database Configurations**: MAXDOP and other performance settings per mode  
✅ **Completion Summaries**: Comprehensive reporting of imported, skipped, and manual-setup-required objects  
✅ **Integration Tests**: Full test coverage with ALL TESTS PASSED validation  
✅ **Cross-Platform**: Automatic target OS detection with appropriate path handling

### System Architecture

**Export-SqlServerSchema.ps1** (~1725 lines):
- Exports all database objects to numbered folders (00-20)
- FileGroups exported with SQLCMD variables for cross-platform paths
- Manual ALTER DATABASE scripting for parameterized file locations
- No hardcoded paths in exported SQL

**Import-SqlServerSchema.ps1** (~1155 lines):
- Two import modes: Dev (schema-only) vs Prod (full infrastructure)
- Target OS detection for cross-platform path handling
- Database-specific file naming prevents conflicts
- Comprehensive startup configuration display
- Detailed completion summaries with manual action guidance

**Configuration Files**:
- `export-import-config.schema.json`: JSON Schema (draft-07) validation
- Simplified format: `importMode: Dev|Prod` at root level
- Full format: Nested `import.productionMode` / `import.developerMode` structure
- Both formats fully supported with three-tier fallback logic

**Integration Tests** (tests/run-integration-test.ps1):
- Docker-based SQL Server 2022 on Linux
- Two test databases: TestDb_Dev and TestDb_Prod
- Validates export, Dev mode import, Prod mode import
- Comprehensive checks: FileGroups, MAXDOP, Security Policies, data integrity, FK validation

### Known Limitations

**By Design**:
- Database Scoped Credentials: Never exported (secrets cannot be safely extracted)
- Always Encrypted Keys: Require certificate store configuration outside database
- External Data Sources: Environment-specific, require manual configuration per target

**Test Database Exclusions**:
- External Libraries: Require ML Services configuration
- External Languages: Require custom runtime setup
- Certificates with Private Keys: Complex key management not suitable for automated testing

### Next Steps for Production Use

1. **Review Configuration**: Examine sample config files in tests/ folder
2. **Plan FileGroups**: Define fileGroupPathMapping for production servers
3. **Document Secrets**: Identify Database Scoped Credentials requiring manual setup
4. **Test Import**: Run Dev mode import on test server to validate schema
5. **Validate Prod Mode**: Run Prod mode import with FileGroups on staging server
6. **Data Migration**: Use -IncludeData for small databases, consider BCP/SSIS for large tables
7. **Post-Import Tasks**: Configure credentials, validate external connections, enable RLS if needed

### Support & Documentation

- **Main README**: Usage examples, parameter reference, quick start guide
- **EXPORT_IMPORT_STRATEGY.md** (this file): Comprehensive strategy and recommendations
- **MISSING_OBJECTS_ANALYSIS.md**: Analysis of SQL Server object types and coverage
- **tests/README.md**: Docker setup and integration test documentation
- **Copilot Instructions**: .github/copilot-instructions.md with code style conventions

---

## Summary of Changes

### Export Philosophy
- **EXPORT EVERYTHING** - No exceptions, complete schema capture
- **10+ new object types** added to export
- Generate metadata and instruction files for complex objects
- Use placeholders for environment-specific values
- Optional YAML config file for fine-grained control

### Import Philosophy
- **DEVELOPER MODE BY DEFAULT** - Simplify local development
- **Two primary modes**: Dev (default) vs Prod (opt-in via `-ImportMode Prod`)
- Skip environment-specific infrastructure in dev mode (FileGroups, Configs, External)
- Import rare objects by default (harmless if unused, documents database capabilities)
- Disable RLS in dev mode for data visibility
- **Configuration file support** for repeatable, documented deployments
- **Command-line overrides** config file for flexibility
- **Comprehensive reporting** at startup and completion

### Import Philosophy
- **DEVELOPER MODE BY DEFAULT** - Simplify local development
- Skip or modify infrastructure objects (FileGroups, Configs)
- Skip credential objects requiring secrets
- Disable security policies (RLS) by default
- Opt-in to production features via switches

### Key Benefits
1. **Zero-configuration developer experience** - Default mode just works locally
2. **Two-mode simplicity** - Dev (default) vs Prod (opt-in), no complex flag combinations
3. **Complete production fidelity** - All objects captured, including rare edge cases
4. **Security by design** - No secrets in export files, manual setup with clear instructions
5. **Flexible deployment** - Config files for repeatability, command-line for overrides
6. **Clear visibility** - Startup shows configuration, completion shows what was done
7. **Comprehensive reporting** - Automatic detection of credentials, encryption keys, RLS
8. **Documentation included** - Instructions embedded in export, reports explain next steps

This approach balances:
- **Simplicity** for developers (default mode, no flags needed)
- **Completeness** for production (everything exported, including rare objects)
- **Flexibility** for CI/CD (config files + command-line overrides)
- **Safety** for secrets (never exported, clear manual setup instructions)

