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

This metadata enables delta exports and provides an audit trail.

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

This section provides complete documentation of all configuration options. Settings can be specified via:
1. **Command-line parameters** (highest priority)
2. **YAML configuration file** (middle priority)
3. **Default values** (lowest priority)

### 3.1 Command-Line Parameters

#### Export-SqlServerSchema.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Server` | string | *required* | SQL Server instance (e.g., 'localhost', 'server\\SQLEXPRESS') |
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
| `-Server` | string | *required* | Target SQL Server instance |
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

## 6. Further Reading

-   [README.md](../README.md) - Quick start and parameter reference
-   [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md) - Internal architecture and design decisions
-   [DELTA_EXPORT_DESIGN.md](DELTA_EXPORT_DESIGN.md) - Delta export implementation details
-   [tests/README.md](../tests/README.md) - Integration testing with Docker
