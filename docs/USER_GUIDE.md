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

## 3. Configuration via YAML

Instead of long command-line arguments, you can use a YAML configuration file.

**config.yml**:
```yaml
importMode: Dev
includeData: true

export:
  groupByObjectTypes:
    Tables: schema
    Views: schema
    StoredProcedures: schema
  parallel:
    enabled: true
    maxWorkers: 5

# Retry settings for flaky connections
maxRetries: 5
retryDelaySeconds: 10
```

Usage:
```powershell
./Export-SqlServerSchema.ps1 -ConfigFile "config.yml"
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

Exported FileGroup scripts include the original SIZE and FILEGROWTH values from the source database. These can be very large (e.g., 1GB initial size) and may cause imports to fail on developer systems with limited disk space.

**Dev Mode Default Behavior**: In Dev mode, the import automatically uses safe defaults (1 MB initial size, 64 MB growth) unless you override them.

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

**Note**: The size values are in KB. Common conversions:
-   1 MB = 1024 KB
-   64 MB = 65536 KB
-   1 GB = 1048576 KB

## 5. Troubleshooting

-   **Logs**: Check the `export-log.txt` or `import-log.txt` in the output folder.
-   **Connection Errors**: Use `-ConnectionTimeout` (default 30s) if the server is slow to respond.
-   **Throttling**: The script automatically retries on Azure SQL throttling errors (40501, etc.).
