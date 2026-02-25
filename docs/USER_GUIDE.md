# Export-SqlServerSchema User Guide

This guide provides detailed instructions on how to use the Export and Import scripts effectively, covering configuration, modes, and common scenarios.

## 1. Exporting Databases

The `Export-SqlServerSchema.ps1` script exports a database schema (and optional data) into a structured folder hierarchy.

### 1.1 Basic Usage

```powershell
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase"
```

This creates a folder named `DbScripts/localhost_MyDatabase_TIMESTAMP` containing SQL files organized by object type.

### 1.2 Export Modes (Grouping)

You can control how objects are grouped into files using the `GroupingMode` parameter (or YAML config `groupBy`).

| Mode | Files Created | Use Case |
|------|---------------|----------|
| `single` (Default) | One file per object (e.g., `Schema.Table.sql`) | Version control, granular tracking |
| `schema` | One file per schema/type (e.g., `01_dbo_Tables.sql`) | Team-based development |
| `all` | One file per object type (e.g., `01_AllTables.sql`) | CI/CD pipelines, fast deployment |

### 1.3 Parallel Export

For large databases (1000+ objects), use parallel export to speed up the process.

```powershell
./Export-SqlServerSchema.ps1 -Server "bi-server" -Database "DataWarehouse" -Parallel
```

**Note**: Parallel export uses multiple threads (Runspaces). You can control the thread count with `-MaxWorkers` (1-20, default: 5).

### 1.4 Filtering Objects

You can whitelist or blacklist specific object types.

-   **Whitelist**: `-IncludeObjectTypes Tables,Views`
-   **Blacklist**: `-ExcludeObjectTypes Data,SecurityPolicies`

#### Cross-Platform User Filtering

When exporting for Linux SQL Server or a different Windows domain, exclude Windows-authenticated users:

```powershell
# Export for Linux target (exclude Windows users, keep SQL logins)
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" `
    -ExcludeObjectTypes WindowsUsers

# Or in config file:
# excludeObjectTypes:
#   - WindowsUsers
```

**User Type Exclusions:**
| Type | Description |
|------|-------------|
| `WindowsUsers` | Windows domain users and groups (DOMAIN\user) |
| `SqlUsers` | SQL Server login-based users (includes WITHOUT LOGIN users) |
| `ExternalUsers` | Azure AD users and groups |
| `CertificateMappedUsers` | Certificate/asymmetric key mapped users |
| `DatabaseUsers` | All user types (umbrella) |

> **Note on SqlUsers**: When `SqlUsers` is excluded, users created with `WITHOUT LOGIN` (contained database users) are also excluded. These are SQL-type users that exist only within the database without a server-level login. If you need to keep WITHOUT LOGIN users while excluding other SQL users, do not use the `SqlUsers` exclusion.

### 1.5 Delta Export (Incremental)

For databases where most objects rarely change, delta export dramatically reduces export time by only re-scripting modified objects.

```powershell
# First export (full) - creates metadata for future deltas
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase"

# Subsequent exports (delta) - only changed objects
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" `
    -DeltaFrom "./DbScripts/localhost_MyDatabase_20260125_103000"
```

**How Delta Export Works:**

1. Reads `_export_metadata.json` from the previous export
2. Queries SQL Server for current objects with their `modify_date`
3. Compares timestamps to categorize objects:
   - **Modified**: `modify_date` > previous export time
   - **New**: Exists in database but not in previous metadata
   - **Deleted**: Exists in previous metadata but not in database
   - **Unchanged**: Same object, not modified since last export
4. Exports only Modified and New objects
5. Copies Unchanged files from previous export (fast file copy)
6. Logs Deleted objects for review

**Requirements:**
- Previous export must have `_export_metadata.json` (generated automatically)
- Both exports must use `groupBy: single` (the default)
- Server and database must match

**Always-Export Objects:**
Some objects don't have reliable `modify_date` and are always re-exported:
- FileGroups, Schemas, Security (Roles/Users)
- Partition Functions/Schemes, Database Configurations
- Foreign Keys, Indexes (safety measure)

### 1.6 Export Metadata

Every export generates `_export_metadata.json` containing:
- Export timestamp (UTC and server local time)
- Complete object inventory with file paths
- FileGroup details with original sizes (for import reference)
- Grouping mode used
- Encryption objects detected (version 1.1+): DMK, symmetric keys, certificates, asymmetric keys, application roles

This metadata enables delta exports, provides an audit trail, and helps discover required encryption secrets before import.

## 2. Importing Databases

The `Import-SqlServerSchema.ps1` script rebuilds a database from the exported files.

### 2.1 Developer Mode (Default)

Designed for local testing. It:
1.  Skips complex infrastructure (FileGroups, Partitions).
2.  Remaps everything to the `PRIMARY` filegroup (if configured).
3.  Ignores security policies (RLS).

```powershell
./Import-SqlServerSchema.ps1 -Server "localhost" -Database "MyDb_Dev" -SourcePath "./DbScripts/..." -CreateDatabase
```

### 2.2 Production Mode

Designed for full-fidelity deployment. It:
1.  Creates proper FileGroups and Files (requires mapping in config).
2.  Applies Database Scoped Configurations.
3.  Enables Security Policies.

```powershell
./Import-SqlServerSchema.ps1 -Server "prod-sql" -Database "MyDb_Prod" -SourcePath "./DbScripts/..." -ImportMode Prod -ConfigFile "prod-config.yml"
```

## 3. Configuration Reference

**For comprehensive configuration documentation**, see the **[Configuration File Reference](CONFIG_REFERENCE.md)**.

This section provides a quick overview of configuration options. For detailed information including:
- Complete property reference with types, defaults, and ranges
- Encryption secrets configuration
- Object types reference
- Real-world configuration examples for all scenarios
- Troubleshooting guide

Please refer to **[CONFIG_REFERENCE.md](CONFIG_REFERENCE.md)**.

### Quick Configuration Overview

Settings can be specified via:
1. **Command-line parameters** (highest priority)
2. **YAML configuration file** (middle priority)
3. **Default values** (lowest priority)

### Config File Auto-Discovery

When the `-ConfigFile` parameter is not provided, both scripts automatically search for a config file so you do not need to specify it on every run.

**Well-known file names** (searched in order):
1. `export-import-config.yml`
2. `export-import-config.yaml`

**Search locations** (in priority order):
1. Script directory (`$PSScriptRoot`) — for repos where the config lives next to the scripts
2. Current working directory (`$PWD`) — for projects where you invoke the scripts from the repo root

The first match wins. If no file is found the scripts continue with built-in defaults; no warning or error is raised.

**Typical workflow**: commit a `export-import-config.yml` to your repo root (or alongside the scripts) and invoke the scripts without `-ConfigFile`. The right config is picked up automatically.

An explicit `-ConfigFile` parameter always overrides auto-discovery.

### 3.1 Command-Line Parameters

#### Export-SqlServerSchema.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Server` | string | *see note* | SQL Server instance. Required via CLI, `-ServerFromEnv`, or config `connection.serverFromEnv` |
| `-Database` | string | *required* | Database name to export |
| `-OutputPath` | string | ./DbScripts | Output directory for exported scripts |
| `-TargetSqlVersion` | string | Sql2022 | Target SQL version: Sql2012, Sql2014, Sql2016, Sql2017, Sql2019, Sql2022 |
| `-IncludeData` | switch | false | Export table data as INSERT statements |
| `-Credential` | PSCredential | Windows Auth | SQL authentication credentials |
| `-ConfigFile` | string | none | Path to YAML configuration file |
| `-Parallel` | switch | false | Enable parallel export using multiple threads |
| `-MaxWorkers` | int | 5 | Max parallel workers (1-20) |
| `-DeltaFrom` | string | none | Path to previous export for incremental/delta export |
| `-IncludeObjectTypes` | string[] | all | Whitelist: only export specified types |
| `-ExcludeObjectTypes` | string[] | none | Blacklist: exclude specified types |
| `-ConnectionTimeout` | int | 30 | Connection timeout in seconds |
| `-CommandTimeout` | int | 300 | Command timeout in seconds |
| `-MaxRetries` | int | 3 | Max retry attempts for transient failures |
| `-RetryDelaySeconds` | int | 2 | Initial retry delay (uses exponential backoff) |
| `-CollectMetrics` | switch | false | Collect performance metrics for analysis |

#### Import-SqlServerSchema.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Server` | string | *see note* | Target SQL Server instance. Required via CLI, `-ServerFromEnv`, or config `connection.serverFromEnv` |
| `-Database` | string | *required* | Target database name |
| `-SourcePath` | string | *required* | Path to exported schema folder |
| `-ImportMode` | string | Dev | Import mode: Dev or Prod |
| `-Credential` | PSCredential | Windows Auth | SQL authentication credentials |
| `-ConfigFile` | string | none | Path to YAML configuration file |
| `-CreateDatabase` | switch | false | Create database if it doesn't exist |
| `-IncludeData` | switch | false | Import data from 21_Data folder |
| `-IncludeObjectTypes` | string[] | all | Whitelist: only import specified types |
| `-Force` | switch | false | Skip existing schema check |
| `-ContinueOnError` | switch | false | Continue on script errors |
| `-ShowSQL` | switch | false | Display SQL scripts during execution |
| `-ConnectionTimeout` | int | 30 | Connection timeout in seconds |
| `-CommandTimeout` | int | 300 | Command timeout in seconds |
| `-MaxRetries` | int | 3 | Max retry attempts for transient failures |
| `-RetryDelaySeconds` | int | 2 | Initial retry delay (uses exponential backoff) |
| `-CollectMetrics` | switch | false | Collect performance metrics for analysis |

### 3.2 YAML Configuration File Options

#### Root-Level Settings

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `connectionTimeout` | int | 30 | Connection timeout in seconds (1-300) |
| `commandTimeout` | int | 300 | Command timeout in seconds (1-3600) |
| `maxRetries` | int | 3 | Max retry attempts for transient failures (1-10) |
| `retryDelaySeconds` | int | 2 | Initial retry delay in seconds (1-60) |
| `trustServerCertificate` | bool | false | Trust self-signed certificates (for dev/Docker) |

#### Connection Settings (`connection:`)

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `serverFromEnv` | string | none | Env var name containing server address |
| `usernameFromEnv` | string | none | Env var name containing username |
| `passwordFromEnv` | string | none | Env var name containing password |
| `trustServerCertificate` | bool | false | Trust self-signed certificates |

These settings enable credential injection from environment variables, useful for containers and CI/CD:

```yaml
connection:
  usernameFromEnv: SQLCMD_USER
  passwordFromEnv: SQLCMD_PASSWORD
  trustServerCertificate: true
```

Alternatively, use CLI parameters: `-UsernameFromEnv SQLCMD_USER -PasswordFromEnv SQLCMD_PASSWORD -TrustServerCertificate`

#### Export Settings (`export:`)

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `includeData` | bool | false | Export table data as INSERT statements |
| `excludeObjectTypes` | string[] | [] | Object types to exclude from export |
| `excludeObjects` | string[] | [] | Specific objects to exclude (supports wildcards: `staging.*`) |
| `excludeSchemas` | string[] | [] | Schemas to exclude entirely |
| `groupByObjectTypes` | object | {} | File grouping strategy per object type |
| `parallel.enabled` | bool | false | Enable parallel export processing |
| `parallel.maxWorkers` | int | 5 | Number of parallel workers (1-20) |
| `parallel.progressInterval` | int | 50 | Report progress every N items |
| `deltaFrom` | string | none | Path to previous export for delta/incremental export |

**groupByObjectTypes values**: `single` (one file per object), `schema` (group by schema), `all` (all in one file)

#### Import Settings (`import:`)

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `defaultMode` | string | Dev | Default import mode: Dev or Prod |
| `dependencyRetries.enabled` | bool | true | Enable dependency retry logic |
| `dependencyRetries.maxRetries` | int | 10 | Max retry attempts for dependencies (1-10) |
| `dependencyRetries.objectTypes` | string[] | [Functions, StoredProcedures, Views] | Types to retry together |

#### Import Mode Settings (`import.developerMode:` / `import.productionMode:`)

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `fileGroupStrategy` | string | autoRemap | FileGroup handling: `autoRemap` (import with auto-detected paths) or `removeToPrimary` (skip FileGroups) |
| `includeConfigurations` | bool | false | Import database scoped configurations |
| `includeExternalData` | bool | false | Import external data sources |
| `enableSecurityPolicies` | bool | false | Enable Row-Level Security (STATE ON) |
| `includeData` | bool | false | Import table data |
| `excludeObjectTypes` | string[] | [] | Object types to exclude in this mode |
| `fileGroupPathMapping` | object | {} | Map FileGroup names to physical paths (optional, paths auto-detected) |
| `fileGroupFileSizeDefaults.sizeKB` | int | 1024 | Initial file size in KB |
| `fileGroupFileSizeDefaults.fileGrowthKB` | int | 65536 | File growth increment in KB |
| `externalConnectionStrings` | object | {} | Map external data source names to URLs |
| `encryptionSecrets` | object | {} | Encryption key passwords (see Section 4.4) |

### 3.3 Example Configuration Files

**Minimal Configuration (works for both export and import):**
```yaml
# Minimal config - all settings have sensible defaults
# Only needed if using Docker/self-signed certificates
trustServerCertificate: true
```

**Minimal Dev Import Configuration:**
```yaml
importMode: Dev
trustServerCertificate: true
```

**Full Export with Parallel Processing:**
```yaml
export:
  parallel:
    enabled: true
    maxWorkers: 8
  groupByObjectTypes:
    Tables: single
    Views: single
    StoredProcedures: single
  excludeSchemas:
    - staging
    - temp
```

**Production Import Configuration:**
```yaml
import:
  defaultMode: Prod
  productionMode:
    fileGroupStrategy: autoRemap  # Default: auto-detects paths
    includeConfigurations: true
    enableSecurityPolicies: true
    # Optional: override auto-detected paths
    fileGroupPathMapping:
      FG_DATA: "E:\\SQLData\\"
      FG_INDEX: "E:\\SQLIndexes\\"
    fileGroupFileSizeDefaults:
      sizeKB: 1048576      # 1 GB
      fileGrowthKB: 262144  # 256 MB

connectionTimeout: 60
commandTimeout: 600
maxRetries: 5
```

**Delta Export Configuration:**
```yaml
export:
  deltaFrom: "./exports/localhost_MyDb_20260125_100000"
  parallel:
    enabled: true
```

## 4. Advanced Features

### 4.1 Dependency Retry Logic
SQL Server objects often have circular dependencies (Function A calls View B, View B calls Function A). The import script handles this automatically:

1.  Attempts to create all programmability objects.
2.  Catches failures caused by missing dependencies.
3.  Retries failed objects in subsequent passes (up to 10 times).

### 4.2 FileGroup Mapping (Prod Mode)
In Production mode, you must tell the script where to create physical files for each FileGroup.

```yaml
fileGroupPathMapping:
  FG_DATA: "D:\\SQLData\\"
  FG_INDEX: "E:\\SQLIndexes\\"
```

### 4.3 FileGroup File Size Defaults

Exported FileGroup scripts use **SQLCMD variables** for SIZE and FILEGROWTH values, allowing flexible configuration at import time. The original values from the source database are preserved in `_export_metadata.json` for reference.

**Exported SQL Example:**
```sql
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'TestDb_Archive',
    FILENAME = N'$(FG_ARCHIVE_PATH_FILE)',
    SIZE = $(FG_ARCHIVE_SIZE),
    FILEGROWTH = $(FG_ARCHIVE_GROWTH)
) TO FILEGROUP [FG_ARCHIVE];
```

**Dev Mode Default Behavior**: In Dev mode, the import automatically uses safe defaults (1 MB initial size, 64 MB growth) unless you override them. If no config is provided, the original values from `_export_metadata.json` are used.

**Custom Configuration**: You can override these values in either mode via the config file:

```yaml
# At root level (applies to all modes)
fileGroupFileSizeDefaults:
  sizeKB: 1024       # 1 MB initial file size
  fileGrowthKB: 65536  # 64 MB file growth increment

# Or per-mode (nested under import.developerMode or import.productionMode)
import:
  developerMode:
    fileGroupFileSizeDefaults:
      sizeKB: 1024
      fileGrowthKB: 65536
  productionMode:
    fileGroupFileSizeDefaults:
      sizeKB: 1048576    # 1 GB initial size for production
      fileGrowthKB: 262144  # 256 MB growth for production
```

**Value Resolution Order:**
1. Config file `fileGroupFileSizeDefaults` (highest priority)
2. Original values from `_export_metadata.json`
3. Dev mode safe defaults (1 MB / 64 MB)

**Note**: The size values are in KB. Common conversions:
-   1 MB = 1024 KB
-   64 MB = 65536 KB
-   1 GB = 1048576 KB

### 4.4 Encryption Secrets

When importing databases that use encryption features (Database Master Key, Symmetric Keys, Certificates with private keys, Application Roles), you must provide the encryption passwords. SQL Server cannot export these passwords, so they must be supplied during import.

#### Secret Sources

Secrets can be provided from three sources (in order of security):

| Source | Syntax | Use Case |
|--------|--------|----------|
| Environment Variable | `env: VAR_NAME` | **Recommended** for CI/CD and production |
| File | `file: /path/to/secret.txt` | **Recommended** for Kubernetes/containers |
| Inline Value | `value: "password"` | **Development only** - never commit to git! |

#### Configuration Examples

**Developer Mode (with inline secrets for local testing):**
```yaml
import:
  developerMode:
    encryptionSecrets:
      # Database Master Key - required if database uses encryption
      databaseMasterKey:
        value: "DevMasterKeyPwd!123"  # DEV ONLY!

      # Symmetric key passwords
      symmetricKeys:
        DataEncryptionKey:
          value: "DevSymKeyPwd!123"

      # Application role passwords
      applicationRoles:
        TestAppRole:
          value: "TestAppRolePwd!123"
```

**Production Mode (with environment variables):**
```yaml
import:
  productionMode:
    encryptionSecrets:
      databaseMasterKey:
        env: SQL_MASTER_KEY_PWD

      symmetricKeys:
        DataEncryptionKey:
          env: SQL_DATA_KEY_PWD
        BackupEncryptionKey:
          file: "/secrets/backup-key.txt"

      certificates:
        SigningCert:
          env: SQL_SIGNING_CERT_PWD

      applicationRoles:
        App_ReadOnly:
          env: SQL_APPROLE_READONLY_PWD
```

**Kubernetes Deployment (with mounted secrets):**
```yaml
import:
  productionMode:
    encryptionSecrets:
      databaseMasterKey:
        file: "/mnt/secrets/db-master-key"
      symmetricKeys:
        DataEncryptionKey:
          file: "/mnt/secrets/data-key"
```

#### Security Best Practices

1. **Never use inline `value:` in production** - The import script will warn if inline secrets are used in Prod mode.
2. **Never commit secrets to version control** - Use `.gitignore` or separate secret files.
3. **Use environment variables for CI/CD** - Set secrets in your pipeline's secure variables.
4. **Use file-based secrets for Kubernetes** - Mount secrets as volumes.
5. **Rotate secrets regularly** - Update passwords periodically.

#### How It Works

1. The import script reads `encryptionSecrets` from the config for the current mode (Dev/Prod).
2. Each secret is resolved from its source (env var, file, or inline value).
3. When processing security scripts (symmetric keys, application roles, etc.), the script replaces placeholder passwords with the resolved secrets.
4. If a required secret is missing, a warning is displayed with guidance on how to configure it.

#### Discovering Required Secrets

To find out what encryption secrets an export requires **before importing**, use the `-ShowRequiredSecrets` switch:

```powershell
# Scan export and show required secrets with suggested configuration
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb `
    -SourcePath ".\exports\MyDb_20260129" -ShowRequiredSecrets
```

This will:
1. Read encryption metadata from `_export_metadata.json` (or scan SQL files if not available)
2. Display all encryption objects found (DMK, symmetric keys, certificates, app roles)
3. Generate a ready-to-use YAML configuration template

Example output:
```
======================================================================
  ENCRYPTION SECRETS REQUIRED FOR IMPORT
======================================================================

Encryption Objects Found:
  [*] Database Master Key
  [*] Symmetric Keys (1):
      - DataEncryptionKey
  [*] Application Roles (2):
      - ReportingAppRole
      - DataEntryRole

----------------------------------------------------------------------
  SUGGESTED YAML CONFIGURATION
----------------------------------------------------------------------

    encryptionSecrets:
      databaseMasterKey:
        env: SQL_DMK_PASSWORD
      symmetricKeys:
        DataEncryptionKey:
          env: SQL_SYMKEY_DATAENCRYPTIONKEY
      applicationRoles:
        ReportingAppRole:
          env: SQL_APPROLE_REPORTINGAPPROLE
        DataEntryRole:
          env: SQL_APPROLE_DATAENTRYROLE
```

> **Note**: The export script automatically detects encryption objects and stores them in `_export_metadata.json` (version 1.1+). For older exports without metadata, the import script falls back to scanning SQL files.

## 5. Troubleshooting

### Common Issues

-   **Logs**: Check the `export-log.txt` or `import-log.txt` in the output folder.
-   **Connection Errors**: Use `-ConnectionTimeout` (default 30s) if the server is slow to respond.
-   **Throttling**: The script automatically retries on Azure SQL throttling errors (40501, etc.).
-   **Disk Space**: Use `fileGroupFileSizeDefaults` in config to reduce FileGroup file sizes for dev.

### Delta Export Issues

-   **"GroupBy must be 'single'"**: Delta export requires `groupBy: single` for both exports.
-   **"Metadata not found"**: Ensure the previous export contains `_export_metadata.json`.
-   **"Server/Database mismatch"**: Delta exports must be between the same server and database.

### FileGroup Issues

-   **"Cannot create file"**: Check disk space and permissions on target path.
-   **Large file sizes**: Production databases may have large FileGroup sizes. Use config to override.
-   **Path variables not substituted**: Ensure config has `fileGroupPathMapping` for Prod mode.

### Encryption Issues

-   **"No secret configured for symmetric key"**: Add the key name to `encryptionSecrets.symmetricKeys` in your config.
-   **"Environment variable not set"**: Set the environment variable before running the import script.
-   **"Secret file not found"**: Verify the file path is correct and accessible.
-   **"SECURITY WARNING in Prod mode"**: You're using inline `value:` secrets in production - switch to `env:` or `file:`.
-   **"Script failed for 'KeyName'"**: SMO cannot export encryption key definitions - this is expected. Configure secrets in the import config instead.

## 6. Further Reading

-   [README.md](../README.md) - Quick start and parameter reference
-   [CONFIG_REFERENCE.md](CONFIG_REFERENCE.md) - Comprehensive configuration file documentation
-   [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md) - Internal architecture and design decisions
-   [DELTA_EXPORT_DESIGN.md](DELTA_EXPORT_DESIGN.md) - Delta export implementation details
-   [tests/README.md](../tests/README.md) - Integration testing with Docker
