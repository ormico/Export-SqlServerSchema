# Configuration File Reference

Comprehensive reference for the Export-SqlServerSchema YAML configuration file.

## Table of Contents

1. [Overview](#overview)
2. [Configuration File Basics](#configuration-file-basics)
3. [Configuration Property Reference](#configuration-property-reference)
   - [Global Settings](#global-settings)
   - [Connection Settings](#connection-settings)
   - [Export Settings](#export-settings)
   - [Import Settings](#import-settings)
   - [Developer Mode Settings](#developer-mode-settings)
   - [Production Mode Settings](#production-mode-settings)
4. [Configuration Examples](#configuration-examples)
5. [Common Configuration Scenarios](#common-configuration-scenarios)
6. [Configuration Precedence](#configuration-precedence)
7. [Validation and Schema](#validation-and-schema)
8. [Troubleshooting](#troubleshooting)

---

## Overview

The Export-SqlServerSchema toolkit uses YAML configuration files to control export and import behavior. Configuration files provide:

- **Centralized settings management** - Store team defaults in version control
- **Environment-specific configurations** - Separate configs for dev, test, and production
- **Simplified command lines** - Avoid long parameter lists
- **Repeatable operations** - Ensure consistent behavior across runs

**Key principle**: Every configuration property has a sensible default. An empty configuration file is valid!

## Configuration File Basics

### File Format

Configuration files use YAML format (`.yml` or `.yaml` extension):

```yaml
# Comments start with hash
connectionTimeout: 30
commandTimeout: 300

export:
  includeData: false
  excludeSchemas:
    - staging
    - temp
```

### Using Configuration Files

Specify the configuration file using the `-ConfigFile` parameter:

```powershell
# Export with config
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ConfigFile myconfig.yml

# Import with config
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./export -ConfigFile myconfig.yml
```

### Auto-Discovery

When `-ConfigFile` is not specified, both scripts automatically search for a config file using the following well-known names (checked in order):

1. `export-import-config.yml`
2. `export-import-config.yaml`

Search locations, in priority order:

| Priority | Location | Description |
|----------|----------|-------------|
| 1 | Script directory (`$PSScriptRoot`) | Config lives alongside the scripts in a repo |
| 2 | Current working directory (`$PWD`) | Config lives in the project root where you invoke the script |

The first match found is used. If no config file is found, the scripts continue with built-in defaults — no error is raised.

**Example**: Place `export-import-config.yml` in the same folder as the scripts or in your project root, and it will be picked up automatically without specifying `-ConfigFile`.

When auto-discovery is active, the script reports what it found:
```text
[INFO] Using config file: /path/to/export-import-config.yml (auto-discovered)
```

Or when nothing is found:
```text
[INFO] No config file found, using defaults
```

An explicit `-ConfigFile` parameter always takes priority over auto-discovery.

### Minimal Configuration

The simplest valid configuration is an empty file or a file with only needed settings:

```yaml
# Minimal config for Docker/dev environments
trustServerCertificate: true
```

### Example Configuration File

A complete example with all options is available at: [`export-import-config.example.yml`](../export-import-config.example.yml)

---

## Configuration Property Reference

### Global Settings

Settings that apply to both export and import operations.

#### `connectionTimeout`

- **Type**: Integer
- **Default**: `30`
- **Range**: 1-300 seconds
- **Description**: Time to wait when establishing initial connection to SQL Server
- **When to adjust**: Increase for slow networks or Azure SQL Database

```yaml
connectionTimeout: 60  # 1 minute for slow networks
```

#### `commandTimeout`

- **Type**: Integer
- **Default**: `300`
- **Range**: 1-3600 seconds
- **Description**: Time to wait for individual SQL commands to complete
- **When to adjust**: Increase for large databases, complex queries, or slow storage

```yaml
commandTimeout: 900  # 15 minutes for large operations
```

#### `maxRetries`

- **Type**: Integer
- **Default**: `3`
- **Range**: 1-10
- **Description**: Maximum retry attempts for transient failures
- **Handles**: Network timeouts, Azure SQL throttling, deadlocks
- **Behavior**: Set to 1 to disable retries

```yaml
maxRetries: 5  # More aggressive retries for flaky connections
```

#### `retryDelaySeconds`

- **Type**: Integer
- **Default**: `2`
- **Range**: 1-60 seconds
- **Description**: Initial retry delay; uses exponential backoff (doubles each retry)
- **Example**: With `retryDelaySeconds: 2` and `maxRetries: 3`: 2s, 4s, 8s delays

```yaml
retryDelaySeconds: 5  # Longer initial delay
```

#### `trustServerCertificate`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Trust server certificates without validation
- **Set to true for**:
  - Local development environments
  - Docker containers with self-signed certificates
  - SQL Server 2022+ with default encryption
- **Set to false for**:
  - Production environments with valid certificates
  - Environments with proper PKI infrastructure

```yaml
trustServerCertificate: true  # Required for Docker/self-signed certs
```

**Common error resolved**: If you get certificate verification errors like "The certificate chain was issued by an authority that is not trusted", set this to `true`.

#### `collectMetrics`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Collect detailed performance metrics and save to JSON file
- **Use case**: Benchmarking export/import operations, performance tuning
- **Output**: Creates `*_metrics.json` file alongside export/import logs

```yaml
collectMetrics: true  # Enable for performance analysis
```

### Connection Settings

The `connection:` section enables credential injection from environment variables. This is useful for containers, CI/CD pipelines, and any scenario where secrets are provided as environment variables.

#### `connection.serverFromEnv`

- **Type**: String
- **Default**: none
- **Description**: Name of an environment variable containing the SQL Server address
- **Precedence**: Only used when `-Server` is not explicitly provided on the command line

```yaml
connection:
  serverFromEnv: SQLCMD_SERVER
```

#### `connection.usernameFromEnv`

- **Type**: String
- **Default**: none
- **Description**: Name of an environment variable containing the SQL authentication username
- **Requirement**: Must be paired with `passwordFromEnv`

```yaml
connection:
  usernameFromEnv: SQLCMD_USER
```

#### `connection.passwordFromEnv`

- **Type**: String
- **Default**: none
- **Description**: Name of an environment variable containing the SQL authentication password
- **Requirement**: Must be paired with `usernameFromEnv`
- **Security**: The password value is never written to verbose output, error logs, or error tracking

```yaml
connection:
  passwordFromEnv: SQLCMD_PASSWORD
```

#### `connection.trustServerCertificate`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Trust server certificates without validation (same as root-level `trustServerCertificate`)
- **Note**: The root-level `trustServerCertificate` setting continues to work. This is an alternative location within the `connection:` section.

```yaml
connection:
  trustServerCertificate: true
```

#### Complete Connection Example

```yaml
connection:
  serverFromEnv: SQLCMD_SERVER
  usernameFromEnv: SQLCMD_USER
  passwordFromEnv: SQLCMD_PASSWORD
  trustServerCertificate: true
```

#### Credential Precedence

1. **Explicit CLI parameters** (`-Credential`, `-Server`) — highest priority
2. **CLI `*FromEnv` parameters** (`-UsernameFromEnv`, `-PasswordFromEnv`, `-ServerFromEnv`)
3. **Config file `connection:` section** (`connection.usernameFromEnv`, etc.)
4. **Default** — Windows integrated authentication

#### `targetSqlVersion`

- **Type**: String (Enum)
- **Default**: `Sql2022`
- **Valid values**: `Sql2012`, `Sql2014`, `Sql2016`, `Sql2017`, `Sql2019`, `Sql2022`
- **Description**: Target SQL Server version for generated scripts
- **Effect**: Controls syntax compatibility (newer features excluded for older versions)

```yaml
targetSqlVersion: Sql2019  # Target SQL Server 2019
```

#### Simplified Root-Level Settings

These root-level properties provide shortcuts for common settings. They are alternatives to nested import settings.

##### `importMode`

- **Type**: String (Enum)
- **Default**: `Dev`
- **Valid values**: `Dev`, `Prod`
- **Description**: Simplified import mode setting (alternative to `import.defaultMode`)
- **Equivalent to**: `import.defaultMode`

```yaml
importMode: Prod  # Use production mode by default
```

##### `includeData`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Simplified data import setting (alternative to mode-specific settings)
- **Equivalent to**: `import.developerMode.includeData` or `import.productionMode.includeData`

```yaml
includeData: true  # Import table data
```

---

### Export Settings

Settings under the `export:` section control export behavior.

#### `export.includeData`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Export table data as INSERT statements
- **Performance impact**: Significantly increases export time for large tables
- **File location**: Data exported to `21_Data/` folder

```yaml
export:
  includeData: true  # Export schema and data
```

#### `export.includeObjectTypes`

- **Type**: Array of strings
- **Default**: All types included
- **Description**: Whitelist of object types to include (if specified, ONLY these types exported)
- **Mutually exclusive with**: `excludeObjectTypes`
- **Valid values**: See [Object Types Reference](#object-types-reference)

```yaml
export:
  includeObjectTypes:
    - Tables
    - Views
    - StoredProcedures
    - Functions
```

**Use case**: Export only programmability objects for code deployment.

#### `export.excludeObjectTypes`

- **Type**: Array of strings
- **Default**: Empty (nothing excluded)
- **Description**: Blacklist of object types to exclude from export
- **Mutually exclusive with**: `includeObjectTypes`
- **Valid values**: See [Object Types Reference](#object-types-reference)

```yaml
export:
  excludeObjectTypes:
    - Data                    # Skip data export
    - SecurityPolicies        # Skip RLS policies
    - WindowsUsers           # Skip Windows-authenticated users
```

**Use case**: Export for cross-platform deployment (exclude Windows-specific objects).

#### `export.excludeObjects`

- **Type**: Array of strings (patterns)
- **Default**: Empty
- **Description**: Specific objects to exclude using `schema.objectname` pattern
- **Supports wildcards**: `*` matches any characters
- **Pattern**: `schema.objectname`

```yaml
export:
  excludeObjects:
    - "dbo.LegacyTable"        # Exclude specific table
    - "staging.*"              # Exclude entire staging schema
    - "*.TempTable"            # Exclude all TempTable objects
    - "dbo.sp_Old*"            # Exclude old stored procedures
```

#### `export.excludeSchemas`

- **Type**: Array of strings
- **Default**: Empty
- **Description**: Schemas to exclude entirely from export
- **Effect**: Excludes all objects in specified schemas

```yaml
export:
  excludeSchemas:
    - staging                  # Temporary staging area
    - temp                     # Temporary objects
    - archive                  # Archived/deprecated objects
```

#### `export.groupByObjectTypes`

- **Type**: Object (key-value pairs)
- **Default**: All object types use `single` mode
- **Description**: File grouping strategy per object type
- **Modes**:
  - `single`: One file per object (default, best for Git tracking)
  - `schema`: Group by schema into numbered files
  - `all`: All objects of type in one file (minimal file count)

```yaml
export:
  groupByObjectTypes:
    Tables: single              # One file per table (best for Git)
    Views: schema               # Group views by schema
    StoredProcedures: single    # One file per procedure
    Functions: schema           # Group functions by schema
    PartitionFunctions: all     # All partition functions in one file
```

**Note**: FileGroups do not support grouping modes - they always export to a single consolidated file (`001_FileGroups.sql`).

**Delta export requirement**: Delta export requires `groupBy: single` (the default). Other modes are not compatible with delta exports.

#### `export.parallel`

Parallel export settings for improved performance on large databases.

##### `export.parallel.enabled`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Enable parallel export processing
- **Effect**: Uses multiple threads (PowerShell runspaces) for concurrent object export
- **Alternative**: Use `-Parallel` command-line switch

```yaml
export:
  parallel:
    enabled: true
```

##### `export.parallel.maxWorkers`

- **Type**: Integer
- **Default**: `5`
- **Range**: 1-20
- **Description**: Number of parallel worker threads
- **Performance**: More workers = faster export, but diminishing returns beyond 10
- **Consider**: CPU cores, SQL Server load, network bandwidth

```yaml
export:
  parallel:
    enabled: true
    maxWorkers: 8  # 8 parallel workers
```

##### `export.parallel.progressInterval`

- **Type**: Integer
- **Default**: `50`
- **Description**: Report progress every N items completed
- **Effect**: Controls console output frequency

```yaml
export:
  parallel:
    enabled: true
    progressInterval: 100  # Report every 100 objects
```

#### `export.deltaFrom`

- **Type**: String (file path)
- **Default**: None (full export)
- **Description**: Path to previous export for delta/incremental export
- **Effect**: Only changed objects are re-exported; unchanged objects copied from previous export
- **Requirements**:
  - Previous export must have `_export_metadata.json`
  - Both exports must use `groupBy: single`
  - Server and database must match

```yaml
export:
  deltaFrom: "./exports/localhost_MyDatabase_20260125_103000"
```

**Use case**: Dramatically reduce export time for large databases with few changes.

#### `export.stripFilestream`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Strip FILESTREAM features from exported scripts
- **When to use**: Targeting SQL Server on Linux (which doesn't support FILESTREAM)
- **What it does**:
  - Removes `FILESTREAM_ON` clauses from table definitions
  - Removes `FILESTREAM` keyword from `VARBINARY(MAX)` columns
  - Removes FILESTREAM FileGroup definitions

```yaml
export:
  stripFilestream: true  # Export for Linux target
```

**Alternative**: Use `import.*.stripFilestream` for import-time stripping.

---

### Import Settings

Settings under the `import:` section control import behavior.

#### `import.defaultMode`

- **Type**: String (Enum)
- **Default**: `Dev`
- **Valid values**: `Dev`, `Prod`
- **Description**: Default import mode (Developer or Production)
- **Effect**: Determines which mode settings (`developerMode` or `productionMode`) are used

```yaml
import:
  defaultMode: Prod  # Use production settings by default
```

**Can be overridden** by `-ImportMode` command-line parameter.

#### `import.createDatabase`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Create target database if it doesn't exist
- **Requires**: Appropriate server-level permissions (`CREATE DATABASE`)

```yaml
import:
  createDatabase: true  # Auto-create database
```

#### `import.force`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Skip check for existing schema and apply all scripts
- **Use with caution**: May cause errors if objects already exist
- **Use case**: Re-running imports with idempotent scripts

```yaml
import:
  force: true  # Force import even if objects exist
```

#### `import.continueOnError`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Continue applying scripts even if individual scripts fail
- **Use case**: Idempotent applications where some scripts may fail due to existing objects

```yaml
import:
  continueOnError: true  # Don't stop on individual errors
```

#### `import.showSql`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Display SQL scripts during execution for debugging
- **Effect**: Prints each SQL statement to console before execution

```yaml
import:
  showSql: true  # Debug mode - show all SQL
```

#### `import.includeObjectTypes`

- **Type**: Array of strings
- **Default**: All types included
- **Description**: Whitelist of object types to include in import
- **Valid values**: See [Import Object Types Reference](#import-object-types-reference)

```yaml
import:
  includeObjectTypes:
    - Tables
    - Views
    - Functions
    - StoredProcedures
```

#### `import.excludeSchemas`

- **Type**: Array of strings
- **Default**: Empty
- **Description**: Schemas to exclude from import
- **Scope**: Only applies to schema-bound object folders (Tables, Views, Functions, etc.)

```yaml
import:
  excludeSchemas:
    - staging
    - temp
```

#### `import.dependencyRetries`

Settings for handling cross-object dependencies in programmability objects.

##### `import.dependencyRetries.enabled`

- **Type**: Boolean
- **Default**: `true`
- **Description**: Enable dependency retry logic for programmability objects
- **How it works**: Multi-pass retry algorithm executes objects up to N times to resolve dependencies

```yaml
import:
  dependencyRetries:
    enabled: true
```

##### `import.dependencyRetries.maxRetries`

- **Type**: Integer
- **Default**: `10`
- **Range**: 1-10
- **Description**: Maximum retry attempts for resolving object dependencies
- **When failures persist**: Likely due to syntax errors or missing external references

```yaml
import:
  dependencyRetries:
    maxRetries: 5  # Reduce retry attempts
```

##### `import.dependencyRetries.objectTypes`

- **Type**: Array of strings
- **Default**: `[Functions, StoredProcedures, Views]`
- **Description**: Object types to retry together as a group
- **Effect**: These types are processed with multiple passes to resolve cross-type dependencies

```yaml
import:
  dependencyRetries:
    objectTypes:
      - Functions
      - StoredProcedures
      - Views
      - Synonyms           # Add if synonyms reference each other
      - TableTriggers      # Add if triggers have dependencies
```

---

### Developer Mode Settings

Settings under `import.developerMode:` control behavior for local development environments.

#### `import.developerMode.fileGroupStrategy`

- **Type**: String (Enum)
- **Default**: `autoRemap`
- **Valid values**: `autoRemap`, `removeToPrimary`
- **Description**: FileGroup handling strategy
  - `autoRemap`: Import FileGroups, auto-detect data paths using `SERVERPROPERTY('InstanceDefaultDataPath')`
  - `removeToPrimary`: Skip FileGroups, remap all references to PRIMARY filegroup

```yaml
import:
  developerMode:
    fileGroupStrategy: removeToPrimary  # Simplify for dev
```

#### `import.developerMode.includeConfigurations`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Import database scoped configurations (MAXDOP, query optimizer settings, etc.)
- **Why default false**: These settings are hardware-specific and may not suit dev machines

```yaml
import:
  developerMode:
    includeConfigurations: true  # Apply DB configurations
```

#### `import.developerMode.includeDatabaseScopedCredentials`

- **Type**: Boolean (always false)
- **Default**: `false`
- **Constraint**: Cannot be true
- **Description**: Database scoped credentials require manual setup with actual secrets
- **Note**: This property is informational only; credentials cannot be imported

```yaml
import:
  developerMode:
    includeDatabaseScopedCredentials: false  # Always false
```

#### `import.developerMode.includeExternalData`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Import external data sources (PolyBase, external tables)
- **Why default false**: Developers may not have access to production Azure resources

```yaml
import:
  developerMode:
    includeExternalData: true  # Import external data sources
```

#### `import.developerMode.enableSecurityPolicies`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Enable Row-Level Security policies (set STATE=ON)
- **Why default false**: Developers need to see all data for debugging
- **Effect**: 
  - `true`: Policies created with STATE=ON (enforced)
  - `false`: Policies created with STATE=OFF (not enforced)

```yaml
import:
  developerMode:
    enableSecurityPolicies: false  # Keep RLS disabled for dev
```

#### `import.developerMode.includeData`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Import table data from export
- **Can be overridden**: `-IncludeData` command-line switch

```yaml
import:
  developerMode:
    includeData: true  # Import data in dev
```

#### `import.developerMode.stripFilestream`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Strip FILESTREAM features during import
- **When to use**: Target is SQL Server on Linux (Docker containers, etc.)
- **Effect**:
  - Removes `FILESTREAM_ON` clauses entirely
  - Converts `VARBINARY(MAX) FILESTREAM` to regular `VARBINARY(MAX)`
  - Skips FILESTREAM FileGroups

```yaml
import:
  developerMode:
    stripFilestream: true  # Target is Linux
```

#### `import.developerMode.convertLoginsToContained`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Convert login-mapped users to contained users (WITHOUT LOGIN)
- **Use case**: Importing to a different server without the same server logins
- **Effect**: Strips `FOR LOGIN` clauses so users can be created without server logins

```yaml
import:
  developerMode:
    convertLoginsToContained: true  # Create contained users
```

#### `import.developerMode.excludeObjectTypes`

- **Type**: Array of strings
- **Default**: Empty
- **Description**: Object types to exclude in developer mode
- **Valid values**: `PlanGuides`, `ExternalLibraries`, `ExternalLanguages`, `SearchPropertyLists`, `Synonyms`

```yaml
import:
  developerMode:
    excludeObjectTypes:
      - PlanGuides           # Environment-specific query hints
      - ExternalLibraries    # ML Services packages
```

#### `import.developerMode.fileGroupPathMapping`

- **Type**: Object (key-value pairs)
- **Default**: Empty (auto-detected)
- **Description**: Map FileGroup names to physical file paths
- **When needed**: Override auto-detected paths or when auto-detection fails

```yaml
import:
  developerMode:
    fileGroupPathMapping:
      FG_DATA: "C:\\SQLData\\Dev\\"
      FG_INDEX: "C:\\SQLData\\Dev\\"
```

#### `import.developerMode.fileGroupFileSizeDefaults`

- **Type**: Object
- **Description**: Override FileGroup file SIZE and FILEGROWTH values
- **Use case**: Prevent large file allocations on dev systems with limited disk

##### `sizeKB`

- **Type**: Integer
- **Default**: `1024` (1 MB)
- **Range**: 64 KB - 1073741824 KB (1 TB)
- **Description**: Initial file size in kilobytes

##### `fileGrowthKB`

- **Type**: Integer
- **Default**: `65536` (64 MB)
- **Range**: 64 KB - 1073741824 KB (1 TB)
- **Description**: File growth increment in kilobytes

```yaml
import:
  developerMode:
    fileGroupFileSizeDefaults:
      sizeKB: 1024         # 1 MB initial size
      fileGrowthKB: 65536  # 64 MB growth
```

**Common sizes**:
- 1 MB = 1024 KB
- 64 MB = 65536 KB
- 1 GB = 1048576 KB

#### `import.developerMode.externalConnectionStrings`

- **Type**: Object (key-value pairs)
- **Default**: Empty
- **Description**: Map external data source names to connection URLs
- **Use case**: Point to dev/test versions of external data sources

```yaml
import:
  developerMode:
    externalConnectionStrings:
      AzureDataLake: "https://devdatalake.blob.core.windows.net/data"
      TestBackup: "https://testbackup.blob.core.windows.net/backup"
```

#### `import.developerMode.encryptionSecrets`

Configuration for encryption object passwords. See [Encryption Secrets Reference](#encryption-secrets-reference).

#### `import.developerMode.clr`

CLR integration and strict security settings for importing databases with CLR assemblies.

- **Type**: Object
- **Description**: Controls CLR assembly loading behavior during import. SQL Server 2017+ defaults to `clr strict security = 1`, which blocks unsigned/untrusted CLR assemblies.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `enableClr` | Boolean | `false` | Enable CLR integration via `sp_configure 'clr enabled'` |
| `disableStrictSecurityForImport` | Boolean | `false` | Temporarily disable `clr strict security` during CLR object import |
| `restoreStrictSecuritySetting` | Boolean | `true` | Restore original `clr strict security` value after import |
| `restoreClrEnabledSetting` | Boolean | `true` | Restore original `clr enabled` value after import |

```yaml
import:
  developerMode:
    clr:
      enableClr: true
      disableStrictSecurityForImport: true     # Required for unsigned assemblies
      restoreStrictSecuritySetting: true        # Restore after import
      restoreClrEnabledSetting: true            # Restore CLR enabled after import
```

> **Note**: Changing `sp_configure` settings requires `sysadmin` or `serveradmin` role. If the import credential lacks permission, a clear warning is emitted.

> **Note**: If CLR assembly import fails and `disableStrictSecurityForImport` is not enabled, the import will emit a `[HINT]` message suggesting the option.

---

### Production Mode Settings

Settings under `import.productionMode:` control behavior for production deployments. Most settings mirror developer mode but with production-appropriate defaults.

#### `import.productionMode.fileGroupStrategy`

- **Type**: String (Enum)
- **Default**: `autoRemap`
- **Valid values**: `autoRemap`, `removeToPrimary`
- **Description**: FileGroup handling strategy (usually `autoRemap` for production)

```yaml
import:
  productionMode:
    fileGroupStrategy: autoRemap  # Preserve FileGroup structure
```

#### `import.productionMode.includeConfigurations`

- **Type**: Boolean
- **Default**: `true`
- **Description**: Import database scoped configurations in production

```yaml
import:
  productionMode:
    includeConfigurations: true
```

#### `import.productionMode.includeExternalData`

- **Type**: Boolean
- **Default**: `true`
- **Description**: Import external data sources in production

```yaml
import:
  productionMode:
    includeExternalData: true
```

#### `import.productionMode.enableSecurityPolicies`

- **Type**: Boolean
- **Default**: `true`
- **Description**: Enable Row-Level Security policies (STATE=ON) in production

```yaml
import:
  productionMode:
    enableSecurityPolicies: true  # Enforce RLS in prod
```

#### `import.productionMode.includeData`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Import table data (can override with `-IncludeData`)

```yaml
import:
  productionMode:
    includeData: false  # Usually data imported separately
```

#### `import.productionMode.stripFilestream`

- **Type**: Boolean
- **Default**: `false`
- **Description**: Strip FILESTREAM features (only if prod target is Linux)

```yaml
import:
  productionMode:
    stripFilestream: false  # Production on Windows supports FILESTREAM
```

#### `import.productionMode.excludeObjectTypes`

- **Type**: Array of strings
- **Default**: Empty (nothing excluded)
- **Description**: Object types to exclude in production mode

```yaml
import:
  productionMode:
    excludeObjectTypes: []  # No exclusions in prod
```

#### `import.productionMode.fileGroupPathMapping`

- **Type**: Object (key-value pairs)
- **Description**: Map FileGroup names to production storage paths
- **Important**: Use appropriate storage (SSD, SAN, etc.) for each FileGroup

```yaml
import:
  productionMode:
    fileGroupPathMapping:
      FG_CURRENT: "E:\\SQLData\\Current"
      FG_ARCHIVE: "F:\\SQLArchive\\Archive"
      FG_HISTORICAL: "G:\\SQLHistory\\Data"
```

#### `import.productionMode.fileGroupFileSizeDefaults`

- **Type**: Object
- **Description**: Production-appropriate file sizes
- **Properties**: `sizeKB`, `fileGrowthKB`

```yaml
import:
  productionMode:
    fileGroupFileSizeDefaults:
      sizeKB: 1048576       # 1 GB initial size
      fileGrowthKB: 262144  # 256 MB growth
```

#### `import.productionMode.externalConnectionStrings`

- **Type**: Object (key-value pairs)
- **Description**: Production external data source URLs

```yaml
import:
  productionMode:
    externalConnectionStrings:
      AzureDataLake: "https://proddatalake.blob.core.windows.net/data"
      ProductionBackup: "https://prodbackup.blob.core.windows.net/backup"
      OnPremDataSource: "sqlserver://prod-server.domain.com/database"
```

#### `import.productionMode.encryptionSecrets`

Configuration for production encryption passwords. **CRITICAL**: Never use inline `value:` secrets in production. See [Encryption Secrets Reference](#encryption-secrets-reference).

#### `import.productionMode.clr`

CLR integration settings for production. Same options as `import.developerMode.clr`.

```yaml
import:
  productionMode:
    clr:
      enableClr: true
      disableStrictSecurityForImport: false    # Production should use signed assemblies
      restoreStrictSecuritySetting: true
      restoreClrEnabledSetting: true
```

> **Best Practice**: In production, prefer signing CLR assemblies rather than disabling strict security. Only set `disableStrictSecurityForImport: true` when migrating legacy unsigned assemblies.

---

### Encryption Secrets Reference

Configuration for encryption object passwords (Database Master Key, Symmetric Keys, Certificates, Application Roles).

#### Secret Source Types

Secrets can be provided from three sources, in order of security:

| Source Type | Syntax | Security | Use Case |
|-------------|--------|----------|----------|
| Environment Variable | `env: VAR_NAME` | High | **Recommended** for CI/CD and production |
| File | `file: /path/to/secret.txt` | High | **Recommended** for Kubernetes/containers |
| Inline Value | `value: "password"` | Low | **Development only** - never commit! |

#### `encryptionSecrets.databaseMasterKey`

- **Description**: Password for creating/opening the Database Master Key (DMK)
- **Required when**: Database uses any encryption features
- **Format**: Secret value object (`env:`, `file:`, or `value:`)

```yaml
encryptionSecrets:
  databaseMasterKey:
    env: SQL_MASTER_KEY_PWD           # Production (environment variable)
    # OR
    file: "/secrets/dbmasterkey.txt"  # Kubernetes (mounted secret)
    # OR
    value: "DevMasterKey!123"         # Development only (inline)
```

#### `encryptionSecrets.symmetricKeys`

- **Description**: Map of symmetric key names to their encryption passwords
- **Format**: Object where keys are symmetric key names, values are secret objects

```yaml
encryptionSecrets:
  symmetricKeys:
    DataEncryptionKey:
      env: SQL_DATA_KEY_PWD
    BackupEncryptionKey:
      file: "/secrets/backup-key.txt"
```

#### `encryptionSecrets.certificates`

- **Description**: Map of certificate names to their private key passwords
- **Note**: Only for certificates with private keys

```yaml
encryptionSecrets:
  certificates:
    DataCert:
      env: SQL_DATACERT_PASSWORD
    SigningCert:
      file: "/secrets/signing-cert-pwd.txt"
```

#### `encryptionSecrets.applicationRoles`

- **Description**: Map of application role names to their passwords

```yaml
encryptionSecrets:
  applicationRoles:
    App_ReadOnly:
      env: SQL_APPROLE_READONLY_PWD
    App_Admin:
      env: SQL_APPROLE_ADMIN_PWD
```

#### Complete Example

**Development (inline secrets for local testing)**:
```yaml
import:
  developerMode:
    encryptionSecrets:
      databaseMasterKey:
        value: "DevMasterKeyPwd!123"
      symmetricKeys:
        DataKey:
          value: "DevDataKeyPwd!123"
      applicationRoles:
        TestRole:
          value: "TestRolePwd!123"
```

**Production (environment variables)**:
```yaml
import:
  productionMode:
    encryptionSecrets:
      databaseMasterKey:
        env: SQL_MASTER_KEY_PWD
      symmetricKeys:
        DataEncryptionKey:
          env: SQL_DATA_KEY_PWD
        BackupKey:
          env: SQL_BACKUP_KEY_PWD
      certificates:
        SigningCert:
          env: SQL_SIGNING_CERT_PWD
      applicationRoles:
        App_ReadOnly:
          env: SQL_APPROLE_READONLY_PWD
```

**Kubernetes (file-based secrets)**:
```yaml
import:
  productionMode:
    encryptionSecrets:
      databaseMasterKey:
        file: "/mnt/secrets/db-master-key"
      symmetricKeys:
        DataKey:
          file: "/mnt/secrets/data-key"
      applicationRoles:
        AppRole:
          file: "/mnt/secrets/app-role-pwd"
```

#### Security Best Practices

1. **Never use inline `value:` in production** - Import script warns if detected
2. **Never commit secrets to version control** - Add config files with secrets to `.gitignore`
3. **Use environment variables for CI/CD** - Store in pipeline secure variables
4. **Use file-based secrets for Kubernetes** - Mount as volumes
5. **Rotate secrets regularly** - Update passwords periodically
6. **Read-only file permissions** - Protect secret files from unauthorized access

#### Discovering Required Secrets

Use the `-ShowRequiredSecrets` switch to discover encryption requirements:

```powershell
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb `
    -SourcePath "./exports/MyDb_20260129" -ShowRequiredSecrets
```

This scans the export and generates a ready-to-use YAML configuration template.

---

## Object Types Reference

### Export Object Types

Valid values for `export.includeObjectTypes` and `export.excludeObjectTypes`:

| Object Type | Description |
|-------------|-------------|
| `FileGroups` | Physical storage layout (filegroups and files) |
| `DatabaseScopedConfigurations` | Performance/optimizer settings (MAXDOP, etc.) |
| `DatabaseScopedCredentials` | External resource credentials |
| `Schemas` | CREATE SCHEMA statements |
| `Sequences` | Sequence objects |
| `PartitionFunctions` | Table partitioning functions |
| `PartitionSchemes` | Partition scheme mappings |
| `UserDefinedTypes` | User-defined data types (UDT/UDTT/UDDT) |
| `XmlSchemaCollections` | XML schema definitions |
| `Tables` | Table definitions (with primary keys only) |
| `ForeignKeys` | Foreign key constraints |
| `Indexes` | Non-clustered indexes |
| `Defaults` | Default constraints |
| `Rules` | Rule constraints |
| `Assemblies` | CLR assemblies |
| `Functions` | User-defined functions (scalar, table-valued, CLR) |
| `UserDefinedAggregates` | CLR aggregates |
| `StoredProcedures` | Stored procedures (regular and extended) |
| `DatabaseTriggers` | Database-level triggers |
| `TableTriggers` | Table-level triggers |
| `Views` | Database views |
| `Synonyms` | Object aliases |
| `FullTextCatalogs` | Full-text catalogs |
| `FullTextStopLists` | Full-text stop lists |
| `ExternalDataSources` | PolyBase external data sources |
| `ExternalFileFormats` | PolyBase external file formats |
| `SearchPropertyLists` | Full-text search properties |
| `PlanGuides` | Query hint overrides |
| `DatabaseRoles` | Database roles |
| `DatabaseUsers` | All database users (umbrella type) |
| `WindowsUsers` | Windows domain users and groups |
| `SqlUsers` | SQL Server login-based users |
| `ExternalUsers` | Azure AD users and groups |
| `CertificateMappedUsers` | Certificate/asymmetric key mapped users |
| `Certificates` | Database certificates |
| `AsymmetricKeys` | Asymmetric keys |
| `SymmetricKeys` | Symmetric keys |
| `ColumnMasterKeys` | Always Encrypted column master keys |
| `ColumnEncryptionKeys` | Always Encrypted column encryption keys |
| `SecurityPolicies` | Row-Level Security policies |
| `Data` | Table data (INSERT statements) |

### Import Object Types

Valid values for `import.includeObjectTypes`:

| Object Type | Description | Equivalent Export Types |
|-------------|-------------|-------------------------|
| `FileGroups` | FileGroups and files | `FileGroups` |
| `DatabaseConfiguration` | Database scoped configurations | `DatabaseScopedConfigurations` |
| `Schemas` | Schemas | `Schemas` |
| `Sequences` | Sequences | `Sequences` |
| `PartitionFunctions` | Partition functions | `PartitionFunctions` |
| `PartitionSchemes` | Partition schemes | `PartitionSchemes` |
| `Types` | User-defined types | `UserDefinedTypes` |
| `XmlSchemaCollections` | XML schemas | `XmlSchemaCollections` |
| `Tables` | Tables | `Tables` |
| `ForeignKeys` | Foreign keys | `ForeignKeys` |
| `Indexes` | Indexes | `Indexes` |
| `Defaults` | Defaults | `Defaults` |
| `Rules` | Rules | `Rules` |
| `Programmability` | All programmability objects | `Assemblies`, `Functions`, `UserDefinedAggregates`, `StoredProcedures`, `Triggers` |
| `Views` | Views | `Views` |
| `Functions` | Functions | `Functions` |
| `StoredProcedures` | Stored procedures | `StoredProcedures` |
| `Synonyms` | Synonyms | `Synonyms` |
| `SearchPropertyLists` | Search property lists | `SearchPropertyLists` |
| `PlanGuides` | Plan guides | `PlanGuides` |
| `DatabaseRoles` | Database roles | `DatabaseRoles` |
| `DatabaseUsers` | Database users | `DatabaseUsers`, `WindowsUsers`, `SqlUsers`, `ExternalUsers`, `CertificateMappedUsers` |
| `SecurityPolicies` | RLS policies | `SecurityPolicies` |
| `Data` | Table data | `Data` |

---

## Configuration Examples

### Minimal Configurations

#### Empty Configuration (All Defaults)

```yaml
# Empty file or minimal content - all defaults apply
# This is valid and works for basic local development!
```

#### Docker/Development with Self-Signed Certificate

```yaml
# Minimal config for Docker SQL Server or dev environments
trustServerCertificate: true
```

#### Simple Import Mode Selection

```yaml
# Use production mode by default
importMode: Prod
```

---

### Export Configurations

#### Basic Export with Exclusions

```yaml
export:
  excludeObjectTypes:
    - Data                    # Skip data
    - SecurityPolicies        # Skip RLS
  excludeSchemas:
    - staging
    - temp
```

#### Parallel Export for Large Database

```yaml
export:
  parallel:
    enabled: true
    maxWorkers: 8
    progressInterval: 100
```

#### Delta Export

```yaml
export:
  deltaFrom: "./exports/localhost_MyDatabase_20260125_103000"
  parallel:
    enabled: true
    maxWorkers: 4
```

#### Cross-Platform Export (Linux Target)

```yaml
export:
  stripFilestream: true       # Remove Windows-only FILESTREAM
  excludeObjectTypes:
    - WindowsUsers           # Exclude Windows auth users
```

#### Grouped Export (Fewer Files)

```yaml
export:
  groupByObjectTypes:
    Tables: single            # One file per table (default)
    Views: schema             # Group views by schema
    StoredProcedures: schema  # Group procs by schema
    Functions: schema         # Group functions by schema
    PartitionFunctions: all   # All partition functions in one file
```

---

### Import Configurations

#### Developer Mode - Minimal Setup

```yaml
import:
  developerMode:
    fileGroupStrategy: removeToPrimary  # Skip FileGroups
    includeConfigurations: false        # Skip DB configs
    enableSecurityPolicies: false       # Disable RLS

trustServerCertificate: true
```

#### Developer Mode - With FileGroups

```yaml
import:
  developerMode:
    fileGroupStrategy: autoRemap        # Import FileGroups
    fileGroupFileSizeDefaults:
      sizeKB: 1024                      # 1 MB files
      fileGrowthKB: 65536               # 64 MB growth
```

#### Developer Mode - Linux Target

```yaml
import:
  developerMode:
    stripFilestream: true               # Strip FILESTREAM
    convertLoginsToContained: true      # No server logins

trustServerCertificate: true
```

#### Production Mode - Full Import

```yaml
import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap
    includeConfigurations: true
    includeExternalData: true
    enableSecurityPolicies: true
    fileGroupPathMapping:
      FG_DATA: "E:\\SQLData\\"
      FG_INDEX: "F:\\SQLIndexes\\"
    fileGroupFileSizeDefaults:
      sizeKB: 1048576                   # 1 GB
      fileGrowthKB: 262144              # 256 MB

connectionTimeout: 60
commandTimeout: 900
maxRetries: 5
```

#### Production Mode - With Encryption

```yaml
import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap
    includeConfigurations: true
    enableSecurityPolicies: true
    encryptionSecrets:
      databaseMasterKey:
        env: SQL_MASTER_KEY_PWD
      symmetricKeys:
        DataEncryptionKey:
          env: SQL_DATA_KEY_PWD
      applicationRoles:
        App_ReadOnly:
          env: SQL_APPROLE_READONLY_PWD

connectionTimeout: 60
commandTimeout: 900
```

---

### Complete Real-World Examples

#### Development Team Configuration

```yaml
# dev-config.yml - Shared team defaults for local development

trustServerCertificate: true
connectionTimeout: 30
commandTimeout: 300

export:
  excludeSchemas:
    - staging
    - temp
    - archive
  groupByObjectTypes:
    Tables: single
    Views: single
    StoredProcedures: single
    Functions: single

import:
  defaultMode: Dev
  developerMode:
    fileGroupStrategy: removeToPrimary
    includeConfigurations: false
    enableSecurityPolicies: false
    includeData: false
    stripFilestream: true
    convertLoginsToContained: true
```

#### CI/CD Pipeline Configuration

```yaml
# ci-config.yml - Fast export/import for CI builds

trustServerCertificate: true
connectionTimeout: 60
commandTimeout: 600
maxRetries: 5

export:
  parallel:
    enabled: true
    maxWorkers: 8
  excludeObjectTypes:
    - Data
    - WindowsUsers
  groupByObjectTypes:
    Tables: single
    Views: single
    StoredProcedures: single

import:
  defaultMode: Dev
  developerMode:
    fileGroupStrategy: removeToPrimary
    stripFilestream: true
```

#### Production Deployment Configuration

```yaml
# prod-config.yml - Full production deployment

connectionTimeout: 120
commandTimeout: 1800
maxRetries: 5
retryDelaySeconds: 5
trustServerCertificate: false

import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap
    includeConfigurations: true
    includeExternalData: true
    enableSecurityPolicies: true
    
    fileGroupPathMapping:
      FG_CURRENT: "E:\\SQLData\\Current"
      FG_ARCHIVE: "F:\\SQLArchive\\Archive"
      FG_HISTORICAL: "G:\\SQLHistory\\Data"
    
    fileGroupFileSizeDefaults:
      sizeKB: 1048576       # 1 GB
      fileGrowthKB: 262144  # 256 MB
    
    externalConnectionStrings:
      AzureDataLake: "https://proddatalake.blob.core.windows.net/data"
      ProductionBackup: "https://prodbackup.blob.core.windows.net/backup"
    
    encryptionSecrets:
      databaseMasterKey:
        env: PROD_SQL_MASTER_KEY_PWD
      symmetricKeys:
        DataEncryptionKey:
          env: PROD_SQL_DATA_KEY_PWD
        BackupKey:
          env: PROD_SQL_BACKUP_KEY_PWD
      applicationRoles:
        App_ReadOnly:
          env: PROD_SQL_APPROLE_READONLY_PWD
        App_Admin:
          env: PROD_SQL_APPROLE_ADMIN_PWD
```

---

## Common Configuration Scenarios

### Scenario 1: Export for Git Version Control

**Goal**: One file per object for granular Git tracking.

```yaml
export:
  groupByObjectTypes:
    Tables: single
    Views: single
    StoredProcedures: single
    Functions: single
```

### Scenario 2: Export for Fast CI/CD Deployment

**Goal**: Fewer files for faster deployment, parallel export.

```yaml
export:
  parallel:
    enabled: true
    maxWorkers: 8
  groupByObjectTypes:
    Tables: single
    Views: schema
    StoredProcedures: schema
    Functions: schema
    PartitionFunctions: all
    PartitionSchemes: all
```

### Scenario 3: Export from Windows, Import on Linux

**Goal**: Strip Windows-specific features (FILESTREAM, Windows users).

```yaml
export:
  stripFilestream: true
  excludeObjectTypes:
    - WindowsUsers

import:
  developerMode:
    stripFilestream: true           # Double-strip for safety
    convertLoginsToContained: true
```

### Scenario 4: Daily Delta Export (Backup Strategy)

**Goal**: Fast incremental backups, only changed objects.

```yaml
export:
  deltaFrom: "./exports/latest"     # Symlink to previous export
  parallel:
    enabled: true
    maxWorkers: 4
```

**Usage**:
```powershell
# Create initial export
./Export-SqlServerSchema.ps1 -Server prod -Database MyDb -ConfigFile delta-config.yml

# Create symlink to latest
New-Item -ItemType SymbolicLink -Path "./exports/latest" -Target "./exports/prod_MyDb_20260130_080000"

# Subsequent exports are fast deltas
./Export-SqlServerSchema.ps1 -Server prod -Database MyDb -ConfigFile delta-config.yml
```

### Scenario 5: Multi-Environment Import (Dev/Test/Prod)

**Goal**: One export, multiple import configs for different environments.

**dev-import.yml**:
```yaml
import:
  defaultMode: Dev
  developerMode:
    fileGroupStrategy: removeToPrimary
    enableSecurityPolicies: false
    stripFilestream: true
trustServerCertificate: true
```

**test-import.yml**:
```yaml
import:
  defaultMode: Dev
  developerMode:
    fileGroupStrategy: autoRemap
    includeConfigurations: true
    enableSecurityPolicies: false
trustServerCertificate: true
```

**prod-import.yml**:
```yaml
import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap
    includeConfigurations: true
    enableSecurityPolicies: true
    fileGroupPathMapping:
      FG_DATA: "E:\\SQLData\\"
    encryptionSecrets:
      databaseMasterKey:
        env: PROD_SQL_MASTER_KEY_PWD
connectionTimeout: 120
commandTimeout: 1800
```

### Scenario 6: Kubernetes Deployment with Secrets

**Goal**: Use mounted secrets for encryption passwords.

**k8s-import.yml**:
```yaml
import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap
    encryptionSecrets:
      databaseMasterKey:
        file: "/mnt/secrets/db-master-key"
      symmetricKeys:
        DataKey:
          file: "/mnt/secrets/data-key"
      applicationRoles:
        AppRole:
          file: "/mnt/secrets/app-role-pwd"

trustServerCertificate: true
```

**Kubernetes Secret**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sql-encryption-secrets
type: Opaque
data:
  db-master-key: <base64-encoded-password>
  data-key: <base64-encoded-password>
  app-role-pwd: <base64-encoded-password>
```

**Pod Volume Mount**:
```yaml
volumeMounts:
  - name: secrets
    mountPath: /mnt/secrets
    readOnly: true
volumes:
  - name: secrets
    secret:
      secretName: sql-encryption-secrets
```

---

## Configuration Precedence

Settings are resolved in this order (highest to lowest priority):

1. **Command-line parameters** (highest priority)
2. **YAML configuration file** (middle priority)
3. **Default values** (lowest priority)

### Examples

**Command-line overrides config**:
```powershell
# Config file has: includeData: false
# Command-line parameter wins
./Import-SqlServerSchema.ps1 -ConfigFile myconfig.yml -IncludeData
# Result: Data IS imported
```

**Config overrides defaults**:
```yaml
# Config file
commandTimeout: 900

# Script default is 300
# Config wins: timeout is 900 seconds
```

**Full precedence chain**:
```yaml
# myconfig.yml
connectionTimeout: 60
```

```powershell
./Export-SqlServerSchema.ps1 -ConfigFile myconfig.yml -ConnectionTimeout 120
# Result: connectionTimeout = 120 (parameter wins)
```

---

## Validation and Schema

### JSON Schema Validation

The configuration file has a JSON schema for validation: `export-import-config.schema.json`

**Enable IntelliSense** in VS Code by adding schema reference:

```yaml
# At the top of your config file
$schema: "./export-import-config.schema.json"

connectionTimeout: 30
# ... rest of config
```

### Schema Location

- **Repository**: `export-import-config.schema.json` in repository root
- **Online**: `https://raw.githubusercontent.com/ormico/Export-SqlServerSchema/main/export-import-config.schema.json`

### Validation Tools

**PowerShell-Yaml Validation** (automatic when loading config):
```powershell
# Scripts automatically validate YAML syntax when loading
./Export-SqlServerSchema.ps1 -ConfigFile myconfig.yml
# Invalid YAML produces clear error messages
```

**JSON Schema Validation** (using VS Code):
1. Open config file in VS Code
2. Add `$schema` reference at top
3. VS Code provides:
   - Auto-completion for property names
   - Inline documentation for properties
   - Validation errors for invalid values

---

## Troubleshooting

### Configuration File Not Found

**Error**: `Config file not found: myconfig.yml`

**Solution**: Verify file path (absolute or relative to current directory)

```powershell
# Check current directory
Get-Location

# Use absolute path
./Export-SqlServerSchema.ps1 -ConfigFile "C:\Path\To\myconfig.yml"
```

### Invalid YAML Syntax

**Error**: `YAML parsing error: ...`

**Common causes**:
- Incorrect indentation (use 2 spaces, not tabs)
- Missing colons after property names
- Unquoted strings with special characters

**Solution**: Validate YAML syntax

```powershell
# Test YAML syntax
$yaml = Get-Content myconfig.yml -Raw
ConvertFrom-Yaml $yaml
```

### Property Not Taking Effect

**Symptom**: Config property seems ignored

**Diagnosis**:
1. Check property name spelling (case-sensitive in YAML)
2. Check command-line parameters (they override config)
3. Check nesting level (property in correct section?)

**Example of incorrect nesting**:
```yaml
# WRONG - enableSecurityPolicies is not a root-level property
enableSecurityPolicies: true

# CORRECT - enableSecurityPolicies inside import.developerMode or import.productionMode
import:
  developerMode:
    enableSecurityPolicies: true
```

**Note**: Some properties like `includeData` and `importMode` are valid at both root level (as shortcuts) and nested level. See [Simplified Root-Level Settings](#simplified-root-level-settings).

### Encryption Secret Not Found

**Error**: `No secret configured for symmetric key 'KeyName'`

**Solution**: Add secret to config

```yaml
import:
  developerMode:
    encryptionSecrets:
      symmetricKeys:
        KeyName:                  # Match exact key name
          value: "password"       # Dev only
          # OR
          env: SQL_KEY_PWD        # Production
```

**Discover required secrets**:
```powershell
./Import-SqlServerSchema.ps1 -SourcePath ./export -ShowRequiredSecrets
```

### Environment Variable Not Set

**Error**: `Environment variable not set: SQL_MASTER_KEY_PWD`

**Solution**: Set environment variable before running import

```powershell
# PowerShell
$env:SQL_MASTER_KEY_PWD = "YourPassword"

# Or in system environment (persistent)
[Environment]::SetEnvironmentVariable("SQL_MASTER_KEY_PWD", "YourPassword", "User")
```

### Secret File Not Found

**Error**: `Secret file not found: /secrets/key.txt`

**Solution**: Verify file path and permissions

```powershell
# Check file exists
Test-Path "/secrets/key.txt"

# Check file permissions (must be readable by script user)
Get-Acl "/secrets/key.txt"
```

### FileGroup Path Issues

**Error**: `Cannot create file '...' - directory does not exist`

**Solution**: Verify paths in `fileGroupPathMapping` exist and are writable

```powershell
# Check path exists
Test-Path "E:\SQLData"

# Create if missing
New-Item -ItemType Directory -Path "E:\SQLData" -Force
```

### Trust Server Certificate Error

**Error**: `The certificate chain was issued by an authority that is not trusted`

**Solution**: Set `trustServerCertificate: true` in config

```yaml
trustServerCertificate: true
```

### Delta Export Validation Errors

**Error**: `GroupBy must be 'single' for delta export`

**Solution**: Ensure both exports use `groupBy: single` (the default)

```yaml
export:
  groupByObjectTypes:
    Tables: single    # Required for delta
    Views: single     # Required for delta
```

**Error**: `Metadata not found in previous export`

**Solution**: Ensure previous export contains `_export_metadata.json`

```powershell
# Check metadata file exists
Test-Path "./exports/previous/_export_metadata.json"
```

### Configuration Conflict Errors

**Error**: `includeObjectTypes and excludeObjectTypes are mutually exclusive`

**Solution**: Use only one of these properties

```yaml
export:
  # PICK ONE:
  includeObjectTypes: [Tables, Views]   # Whitelist approach
  # OR
  excludeObjectTypes: [Data, Security]  # Blacklist approach
```

---

## See Also

- [User Guide](USER_GUIDE.md) - Complete usage guide with examples
- [README.md](../README.md) - Quick start and overview
- [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md) - Architecture and design decisions
- [Example Configuration File](../export-import-config.example.yml) - Fully commented example
- [JSON Schema](../export-import-config.schema.json) - Configuration schema for validation
