# SQL Server Database Scripting Toolkit

PowerShell toolkit for exporting and importing SQL Server database schemas with proper dependency ordering, two-mode deployment system, comprehensive object type support, and enterprise-grade reliability features.

## Origin

I originally started this project in 2012 as a script named `DB2SCRIPT.PS1` along with a number of other database management tools and scripts. Although there are a number of database tools and products that do similar things, this one keeps working for me. 

This latest iteration makes a number of major improvements and brings the code up to PowerShell 7 and adds a testing framework to help ensure everything is working as expected.

## Installation

### Option 1: Download Latest Release

```powershell
# Download latest release (replace VERSION with actual version like v1.2.0)
$version = "VERSION"  # e.g., "v1.2.0"
Invoke-WebRequest -Uri "https://github.com/ormico/Export-SqlServerSchema/releases/download/$version/Export-SqlServerSchema-$version.zip" -OutFile "Export-SqlServerSchema.zip"

# Extract and unblock
Expand-Archive -Path "Export-SqlServerSchema.zip" -DestinationPath "."
Get-ChildItem -Path ".\Export-SqlServerSchema" -Recurse | Unblock-File

# Install required modules
Install-Module SqlServer -Scope CurrentUser
Install-Module powershell-yaml -Scope CurrentUser  # Optional, for YAML config
```

### Option 2: Git Clone (Recommended for Development)

```powershell
# Clone the repository
git clone https://github.com/ormico/Export-SqlServerSchema.git
cd Export-SqlServerSchema

# Unblock downloaded files
Get-ChildItem -Recurse | Unblock-File

# Install required modules
Install-Module SqlServer -Scope CurrentUser
Install-Module powershell-yaml -Scope CurrentUser  # Optional, for YAML config
```

### Prerequisites

- PowerShell 7.0+
- SQL Server 2012+ or Azure SQL Database
- SQL Server Management Objects (SMO): `Install-Module SqlServer -Scope CurrentUser`
- PowerShell YAML module (optional): `Install-Module powershell-yaml -Scope CurrentUser`

## Quick Start

### Export Database

```powershell
# Basic export
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase"

# Export with data
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" -IncludeData

# With SQL authentication
$cred = Get-Credential
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" -Credential $cred

# Parallel export (faster for large databases)
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" -Parallel

# Parallel with custom thread count
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" -Parallel -MaxWorkers 4

# Delta export (only changed objects since previous export)
./Export-SqlServerSchema.ps1 -Server "localhost" -Database "MyDatabase" `
    -DeltaFrom "./DbScripts/localhost_MyDatabase_20260125_103000"
```

### Import Database

```powershell
# Developer Mode (default) - Schema only, no infrastructure
./Import-SqlServerSchema.ps1 -Server "localhost" -Database "DevDatabase" `
    -SourcePath "./DbScripts/localhost_MyDatabase_TIMESTAMP" -CreateDatabase

# Production Mode - Full import with FileGroups and configurations
./Import-SqlServerSchema.ps1 -Server "prodserver" -Database "MyDatabase" `
    -SourcePath "./DbScripts/localhost_MyDatabase_TIMESTAMP" `
    -ImportMode Prod `
    -ConfigFile "./prod-config.yml" `
    -CreateDatabase

# Developer Mode with data
./Import-SqlServerSchema.ps1 -Server "localhost" -Database "DevDatabase" `
    -SourcePath "./DbScripts/localhost_MyDatabase_TIMESTAMP" `
    -IncludeData -CreateDatabase
```

## Key Features

**Export-SqlServerSchema.ps1**
- Exports all database objects (21 folder types)
- Individual files per object (easy version control)
- **Delta export mode** for incremental exports (only changed objects)
- **Parallel export mode** for faster exports on multi-core systems
- Export metadata (`_export_metadata.json`) for delta support and auditing
- FileGroups with SQLCMD variable parameterization (paths, sizes, growth)
- Database Scoped Configurations (MAXDOP, optimizer settings)
- Security Policies (Row-Level Security)
- Search Property Lists, Plan Guides, and more
- Optional data export with INSERT statements
- Cross-platform path handling
- Supports SQL Server 2012-2022, Azure SQL
- **Automatic retry logic** for transient failures (network timeouts, Azure SQL throttling, deadlocks)
- **Configurable timeouts** for slow networks and long-running operations
- **Comprehensive error logging** to file for diagnostics

**Import-SqlServerSchema.ps1**
- **Two import modes**: Dev (default) vs Prod (opt-in)
- **Developer Mode**: Schema-only, skips infrastructure (FileGroups, DB configs)
- **Production Mode**: Full import with FileGroups, MAXDOP, Security Policies
- **Dependency retry logic** for programmability objects (Functions, Views, Stored Procedures)
  - Automatically resolves cross-type dependencies (Function → View, View → Function, etc.)
  - Multi-pass execution with configurable retry count (default: 3 attempts)
  - Handles complex dependency chains without manual intervention
- YAML configuration file support (simplified and full formats)
- Cross-platform FileGroup deployment with target OS detection
- Database-specific file naming prevents conflicts
- Automatic foreign key constraint management
- Comprehensive startup configuration display
- Detailed completion summaries
- Command-line parameters override config files
- **Automatic retry logic** for transient failures with exponential backoff
- **Configurable timeouts** and retry settings via config file or parameters
- **Comprehensive error logging** with connection cleanup guarantees

## Testing

See [tests/README.md](tests/README.md) for comprehensive testing instructions.

Quick test:
```powershell
cd tests
docker-compose up -d
pwsh ./run-integration-test.ps1
```

## Export Output Structure

```
DbScripts/
  ServerName_DatabaseName_TIMESTAMP/
    _DEPLOYMENT_README.md         # Deployment instructions
    _export_metadata.json         # Export metadata (for delta exports)
    00_FileGroups/                # FileGroup definitions with SQLCMD variables
    01_Schemas/                   # Database schemas
    02_Types/                     # User-defined types
    03_Sequences/                 # Sequence objects
    04_PartitionFunctions/        # Partition functions
    05_PartitionSchemes/          # Partition schemes
    06_Tables_PrimaryKey/         # Tables with primary keys
    07_Tables_ForeignKeys/        # Foreign key constraints
    08_Indexes/                   # Indexes
    09_Defaults/                  # Default constraints
    10_Rules/                     # Rule constraints
    11_Programmability/           # Functions, procedures, triggers, views
    12_Synonyms/                  # Synonyms
    13_FullTextSearch/            # Full-text catalogs
    14_Security/                  # Keys, certificates, roles
    15_DatabaseScopedConfigurations/ # MAXDOP, optimizer settings
    16_ExternalDataSources/       # PolyBase/Elastic Query sources
    17_ExternalFileFormats/       # External data file formats
    18_SecurityPolicies/          # Row-Level Security policies
    19_SearchPropertyLists/       # Custom full-text properties
    20_PlanGuides/                # Query hint guides
    21_Data/                      # Optional data INSERT scripts
```

## Common Parameters

### Export-SqlServerSchema.ps1

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Server` | Yes | SQL Server instance |
| `-Database` | Yes | Database to export |
| `-OutputPath` | No | Output directory (default: ./DbScripts) |
| `-IncludeData` | No | Export table data as INSERT statements |
| `-Parallel` | No | Enable parallel export using multiple threads |
| `-MaxWorkers` | No | Max parallel workers (1-20, default: 5) |
| `-DeltaFrom` | No | Path to previous export for incremental/delta export |
| `-Credential` | No | SQL authentication credentials |
| `-TargetSqlVersion` | No | Target SQL version (default: Sql2022) |
| `-IncludeObjectTypes` | No | Whitelist: Only export specified types (e.g., Tables,Views) |
| `-ExcludeObjectTypes` | No | Blacklist: Export all except specified types (e.g., Data) |
| `-ConnectionTimeout` | No | Connection timeout in seconds (default: 0 = use config/30) |
| `-CommandTimeout` | No | Command timeout in seconds (default: 0 = use config/300) |
| `-MaxRetries` | No | Max retry attempts for transient failures (default: 0 = use config/3) |
| `-RetryDelaySeconds` | No | Initial retry delay in seconds (default: 0 = use config/2) |
| `-ConfigFile` | No | Path to YAML configuration file |

### Import-SqlServerSchema.ps1

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Server` | Yes | Target SQL Server instance |
| `-Database` | Yes | Target database name |
| `-SourcePath` | Yes | Path to exported schema folder |
| `-ImportMode` | No | Dev (default) or Prod - Controls infrastructure import |
| `-ConfigFile` | No | Path to YAML configuration file |
| `-CreateDatabase` | No | Create database if it doesn't exist |
| `-IncludeData` | No | Import data from 21_Data folder |
| `-IncludeObjectTypes` | No | Whitelist: Only import specified types (e.g., Schemas,Tables,Views) |
| `-Credential` | No | SQL authentication credentials |
| `-Force` | No | Skip existing schema check (required for multi-pass imports) |
| `-ContinueOnError` | No | Continue on script errors |
| `-ConnectionTimeout` | No | Connection timeout in seconds (default: 0 = use config/30) |
| `-CommandTimeout` | No | Command timeout in seconds (default: 0 = use config/300) |
| `-MaxRetries` | No | Max retry attempts for transient failures (default: 0 = use config/3) |
| `-RetryDelaySeconds` | No | Initial retry delay in seconds (default: 0 = use config/2) |

## Import Modes Explained

**Developer Mode (default)**:
- **FileGroups**: Auto-remap strategy (default) - imports FileGroups with auto-detected paths
  - Automatically detects SQL Server's default data path
  - Creates .ndf files in server's data directory
  - Alternative: `removeToPrimary` strategy skips FileGroups and remaps to PRIMARY
- Skips Database Scoped Configurations (uses server defaults)
- Skips External Data Sources (external dependencies)
- Disables Security Policies (RLS state OFF for data visibility)
- Perfect for local development and testing

**Production Mode (`-ImportMode Prod`)**:
- Imports FileGroups with path mapping from config file
- Applies Database Scoped Configurations (MAXDOP, optimizer settings)
- Imports External Data Sources (with connection strings from config)
- Enables Security Policies (RLS state ON)
- Full fidelity deployment for staging/production

**Selective Overrides**: Command-line parameters override mode defaults and config file settings.

## Delta Export (Incremental)

Delta export enables efficient schema exports by only scripting objects that have changed since a previous export. This dramatically reduces export time for large databases where most objects remain unchanged.

### How It Works

1. **Provide previous export**: Use `-DeltaFrom` to point to a previous export folder
2. **Change detection**: Compares `sys.objects.modify_date` timestamps against previous export
3. **Smart categorization**: Objects classified as Modified, New, Deleted, or Unchanged
4. **Efficient output**: Only changed objects are re-exported; unchanged files are copied

### Usage

```powershell
# Full export (creates metadata for future deltas)
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -OutputPath ./exports

# Delta export (only changed objects since last export)
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -OutputPath ./exports `
    -DeltaFrom "./exports/localhost_MyDb_20260125_100000"
```

### Requirements

- **GroupBy mode**: Must use `groupBy: single` (default) for both exports
- **Same database**: Server and database must match the previous export
- **Metadata file**: Previous export must contain `_export_metadata.json`

### Objects Without modify_date

Some objects don't have reliable modification dates and are **always exported**:
- FileGroups, Schemas, Security (Roles/Users)
- Partition Functions/Schemes
- Database Scoped Configurations
- Foreign Keys, Indexes (always re-exported for safety)

### Performance

For a database with 2,400 objects where only 50 changed:
- **Full export**: ~90 seconds
- **Delta export**: ~15 seconds (copy 2,350 unchanged files + export 50 changed)

See [docs/DELTA_EXPORT_DESIGN.md](docs/DELTA_EXPORT_DESIGN.md) for detailed design documentation.

## Parallel Export

The parallel export feature uses multi-threading to speed up exports of large databases by distributing work across multiple CPU cores.

### When to Use Parallel Export

**Recommended for:**
- Databases with 1,000+ objects (tables, procedures, views, etc.)
- Multi-core servers (4+ cores)
- Time-sensitive backup/migration scenarios

**Not recommended for:**
- Small databases (<500 objects) - overhead outweighs benefits
- Single-core systems
- Network-limited scenarios (SQL Server becomes the bottleneck)

### Performance Characteristics

Based on test database (500 tables, 100 views, 500 procedures, 100 functions, 100 triggers, 2000 indexes):
- **Parallel**: 97.58s export time
- **Sequential**: 93.30s export time
- **Overhead**: 5% slower (acceptable for current database size)

**Note**: The 5% overhead is acceptable because parallel export is designed for scalability with very large databases (10,000+ objects) where parallelization shows significant benefits. For typical databases, sequential export is recommended.

### Usage

```powershell
# Enable parallel export (uses default 5 workers)
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDatabase -Parallel

# Specify custom worker count
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDatabase -Parallel -MaxWorkers 4

# Parallel with other options
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDatabase `
    -Parallel `
    -MaxWorkers 8 `
    -ConfigFile myconfig.yml `
    -IncludeData
```

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Parallel` | False | Enable multi-threaded export |
| `-MaxWorkers` | 5 | Number of worker threads (1-20) |

**YAML Configuration:**
```yaml
export:
  parallel:
    enabled: true
    maxWorkers: 4  # Optional, defaults to 5
```

### Technical Details

- Uses PowerShell runspace pools for thread-safe SMO operations
- Work queue system distributes export tasks evenly across workers
- Each worker maintains its own SMO connection and scripter instance
- Automatic error handling and cleanup for all worker threads
- File writes are serialized to prevent conflicts

### Compatibility

- Works with all grouping modes (`single`, `schema`, `all`)
- Compatible with all object type filters (`-IncludeObjectTypes`, `-ExcludeObjectTypes`)
- Supports all SQL Server versions (2012-2022, Azure SQL)
- Full integration with retry logic and timeout settings

## Export Metadata

Every export generates an `_export_metadata.json` file in the export root folder. This file:

- **Enables delta exports**: Records export timestamp and object inventory
- **Provides audit trail**: Documents what was exported and when
- **Stores FileGroup details**: Preserves original file sizes/paths for reference

### Metadata Contents

```json
{
  "version": "1.0",
  "exportStartTimeUtc": "2026-01-26T15:30:00.000Z",
  "exportStartTimeServer": "2026-01-26T10:30:00.000",
  "serverName": "localhost",
  "databaseName": "TestDb",
  "groupBy": "single",
  "includeData": false,
  "objectCount": 57,
  "objects": [
    { "type": "Table", "schema": "dbo", "name": "Customers", "filePath": "09_Tables_PrimaryKey/dbo.Customers.sql" }
  ],
  "fileGroups": [
    {
      "name": "FG_ARCHIVE",
      "files": [{
        "name": "TestDb_Archive",
        "originalSizeKB": 8192,
        "originalGrowthKB": 65536,
        "sizeVariable": "FG_ARCHIVE_SIZE",
        "growthVariable": "FG_ARCHIVE_GROWTH"
      }]
    }
  ]
}
```

The `fileGroups` array preserves original SIZE and FILEGROWTH values, which are replaced with SQLCMD variables in the exported SQL. This allows the Import script to use config-specified values or fall back to the original values from metadata.

## Export Grouping Modes

Control how objects are organized into files using the `groupBy` configuration setting. This affects file count, Git workflow, and import performance.

### Available Modes

| Mode | Description | File Count | Best For |
|------|-------------|------------|----------|
| **single** | One file per object (default) | Highest (e.g., 2,400) | Git workflows, individual object tracking |
| **schema** | Group objects by schema | Medium (e.g., 101) | Team-based development (schema-per-team) |
| **all** | All objects of same type in one file | Lowest (e.g., 29) | CI/CD pipelines, fast deployments |

### Performance Comparison

Test database: 500 tables, 100 views, 500 procedures, 100 functions, 100 triggers, 2000 indexes

| Mode | Export | Import | Total | Files |
|------|--------|--------|-------|-------|
| single | 93.30s | 20.71s | 114.01s | 2,400 |
| schema | 93.45s | 12.09s | 105.54s | 101 |
| all | 93.89s | 12.19s | 106.08s | 29 |

**Key Findings**:
- Schema/All modes are 7% faster total time (primarily faster imports)
- Export times are similar across all modes (~93s)
- Single mode generates 2,400 files vs 29-101 for schema/all modes

### Usage

```powershell
# Via YAML config
export:
  groupByObjectTypes:
    Tables: schema    # or 'single' or 'all'
    Views: schema
    StoredProcedures: schema

# File examples by mode:
# single:  Schema1.Table1.sql, Schema1.Table2.sql, Schema2.Proc1.sql
# schema:  001_Schema1_Tables.sql, 002_Schema1_Procedures.sql, 003_Schema2_Tables.sql
# all:     001_AllTables.sql, 002_AllProcedures.sql, 003_AllViews.sql
```

### Recommendations

- **Git workflows**: Use `single` mode (default) - each object gets its own file for easy version control
- **Team development**: Use `schema` mode - organize by team ownership (one schema per team)
- **CI/CD pipelines**: Use `all` mode - fastest import times, fewer files to process

## Selective Object Type Filtering

Both Export and Import scripts support filtering which object types to process via command-line parameters.

### Export Filtering

**Whitelist mode** (`-IncludeObjectTypes`): Only export specified types
```powershell
# Export only Tables
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -IncludeObjectTypes Tables

# Export Tables and Views
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -IncludeObjectTypes Tables,Views
```

**Blacklist mode** (`-ExcludeObjectTypes`): Export everything except specified types
```powershell
# Export everything except Data
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ExcludeObjectTypes Data

# Export everything except Security objects
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ExcludeObjectTypes DatabaseRoles,DatabaseUsers

# Export for Linux target (exclude Windows-authenticated users)
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ExcludeObjectTypes WindowsUsers
```

### Import Filtering

**Whitelist mode** (`-IncludeObjectTypes`): Only import specified types
```powershell
# Import only Schemas and Tables (fresh database, no -Force needed)
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./DbScripts/... `
    -IncludeObjectTypes Schemas,Tables

# Import only Views (database already has objects, -Force skips safety check)
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./DbScripts/... `
    -IncludeObjectTypes Views -Force
```

**Why `-Force`?** The Import script checks if the database already contains objects and stops to prevent accidental overwrites. When doing selective imports to an existing database, use `-Force` to bypass this check.

### Multi-Pass Import with -Force Flag

When importing in multiple passes (e.g., structure first, then programmability), the `-Force` flag is **required** for subsequent passes:

```powershell
# PASS 1: Import base structure (empty database)
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./DbScripts/... `
    -IncludeObjectTypes Schemas,Tables,Types -CreateDatabase

# PASS 2: Import programmability (requires -Force since database now has objects)
./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./DbScripts/... `
    -IncludeObjectTypes Functions,Views,StoredProcedures -Force
```

**Understanding -Force**: The Import script has a safety check that stops if the target database already contains objects (tables, views, etc.). This prevents accidental overwrites. After PASS 1 creates tables, PASS 2 would fail this check without `-Force`.

| Scenario | Need `-Force`? |
|----------|----------------|
| Fresh import to empty database | No |
| Multi-pass import (after first pass) | **Yes** |
| Re-deploying to existing database | **Yes** |
| Incremental updates | **Yes** |

**Note**: `-Force` is unrelated to dependency retry logic, which runs automatically to resolve Function→View→Function dependencies.

### Supported Object Types

| Object Type | Export | Import | Notes |
|-------------|--------|--------|-------|
| FileGroups | Yes | Yes | |
| DatabaseConfiguration | Yes | Yes | |
| Schemas | Yes | Yes | |
| Sequences | Yes | Yes | |
| PartitionFunctions | Yes | Yes | |
| PartitionSchemes | Yes | Yes | |
| Types | Yes | Yes | UserDefinedTypes |
| XmlSchemaCollections | Yes | Yes | |
| Tables | Yes | Yes | Includes PKs and FKs |
| ForeignKeys | Yes | Yes | |
| Indexes | Yes | Yes | |
| Defaults | Yes | Yes | |
| Rules | Yes | Yes | |
| Programmability | Yes | Yes | All programmability objects |
| Views | Yes | Yes | Granular (subfolder of Programmability) |
| Functions | Yes | Yes | Granular (subfolder of Programmability) |
| StoredProcedures | Yes | Yes | Granular (subfolder of Programmability) |
| Synonyms | Yes | Yes | |
| SearchPropertyLists | Yes | Yes | |
| PlanGuides | Yes | Yes | |
| DatabaseRoles | Yes | Yes | |
| DatabaseUsers | Yes | Yes | Umbrella for all user types |
| WindowsUsers | Yes | Yes | Windows domain users/groups |
| SqlUsers | Yes | Yes | SQL Server login-based users |
| ExternalUsers | Yes | Yes | Azure AD users/groups |
| CertificateMappedUsers | Yes | Yes | Certificate/AsymmetricKey mapped users |
| SecurityPolicies | Yes | Yes | |
| Data | Yes | Yes | Requires -IncludeData for import |

**Note**: When using granular types (Views, Functions, StoredProcedures), the scripts filter at the subfolder level within 14_Programmability. When using "Programmability", all programmability objects are included.

### Important Considerations

1. **Object Dependencies**: Selective import may fail if dependent objects are missing. For example, importing Views without their dependent Tables or Functions will fail.

2. **Command-line overrides config**: `-IncludeObjectTypes` and `-ExcludeObjectTypes` parameters override any corresponding settings in the YAML config file.

3. **Whitelist vs Blacklist**: You cannot use both `-IncludeObjectTypes` and `-ExcludeObjectTypes` simultaneously. Use whitelist for specific subsets, blacklist for exclusions.

### FileGroup Strategy Examples

**`autoRemap` Strategy** (default in Dev mode):
```sql
-- Exported script contains:
ALTER DATABASE [TestDb] ADD FILEGROUP [FG_CURRENT];
ALTER DATABASE [TestDb] ADD FILE (
    NAME = N'TestDb_Current',
    FILENAME = N'$(FG_CURRENT_PATH_FILE)',
    SIZE = 8MB
) TO FILEGROUP [FG_CURRENT];

CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY
) ON [FG_CURRENT];

-- Import auto-detects default data path and replaces variables:
ALTER DATABASE [TestDb_Dev] ADD FILEGROUP [FG_CURRENT];
ALTER DATABASE [TestDb_Dev] ADD FILE (
    NAME = N'TestDb_Dev_TestDb_Current',
    FILENAME = N'/var/opt/mssql/data/TestDb_Dev_FG_CURRENT_TestDb_Current.ndf',
    SIZE = 8MB
) TO FILEGROUP [FG_CURRENT];

CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY
) ON [FG_CURRENT];
-- Table created on [FG_CURRENT] with auto-generated file path
```

**`removeToPrimary` Strategy** (optional in Dev mode):
```sql
-- Exported script contains:
CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY
) ON [FG_CURRENT];

CREATE PARTITION SCHEME PS_OrderYear
AS PARTITION PF_OrderYear
TO ([FG_ARCHIVE], [FG_CURRENT], [PRIMARY]);

-- Import transforms before execution:
CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY
) ON [PRIMARY];  -- ← Changed from [FG_CURRENT]

CREATE PARTITION SCHEME PS_OrderYear
AS PARTITION PF_OrderYear
ALL TO ([PRIMARY]);  -- ← Changed from TO ([FG_ARCHIVE], [FG_CURRENT], [PRIMARY])

-- FileGroups folder skipped entirely → all objects on PRIMARY
```

## YAML Configuration Files

Use a YAML configuration file instead of long command-line arguments:

**Minimal Configuration** (all settings have sensible defaults):
```yaml
# Only needed for Docker/self-signed certificates
trustServerCertificate: true
```

**Full Configuration Example**:
```yaml
importMode: Dev  # or Prod
includeData: true
trustServerCertificate: true

export:
  parallel:
    enabled: true
    maxWorkers: 4
  groupByObjectTypes:
    Tables: single
    Views: schema
  # deltaFrom: "./exports/previous_export_folder"

import:
  dependencyRetries:
    enabled: true
    maxRetries: 10
  developerMode:
    fileGroupStrategy: autoRemap  # Default: imports FileGroups with auto-detected paths

connectionTimeout: 30
commandTimeout: 300
maxRetries: 3
```

Usage:
```powershell
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ConfigFile config.yml
```

**FileGroup Strategies**:
- **`autoRemap`** (default): Imports FileGroups with auto-detected paths using `SERVERPROPERTY('InstanceDefaultDataPath')`
- **`removeToPrimary`**: Skips FileGroups (note: has known limitations with partitioned tables)

For complete configuration reference including all options, see the [User Guide](docs/USER_GUIDE.md#3-configuration-reference).

## Foreign Key Constraint Management

When importing data, the Import script automatically:
1. Disables all foreign key constraints
2. Imports data in any order (no dependency sorting needed)
3. Re-enables all foreign key constraints
4. Validates referential integrity

This eliminates data import dependency errors and ensures data integrity.

## Reliability & Error Handling

**Automatic Retry Logic**:
- Detects and automatically retries transient failures:
  - Network timeouts and connection issues
  - Azure SQL throttling (error codes 40501, 40613, 49918, 10928, 10929, 40197, 40540, 40143)
  - Deadlocks (error code 1205)
  - Connection pool exhaustion
  - Transport-level errors (error codes 53, 233, 64)
- Uses exponential backoff strategy (default: 2s → 4s → 8s)
- Configurable retry count (1-10, default: 3) and delay (1-60 seconds, default: 2)
- Non-transient errors skip retry logic and fail immediately

**Configurable Timeouts**:
- `connectionTimeout`: Time to establish SQL Server connection (default: 30 seconds)
- `commandTimeout`: Time for long-running commands to complete (default: 300 seconds)
- Configure via YAML file or command-line parameters
- Three-tier precedence: parameter > config file > hardcoded default

**Comprehensive Error Logging**:
- All errors logged to timestamped log file in output directory
- Dual output: console for immediate feedback + file for diagnostics
- Includes full error details, script names, retry attempts
- Connection cleanup guaranteed via finally blocks (prevents resource leaks)

**Example Configuration**:
```yaml
# For slow networks or Azure SQL
connectionTimeout: 60
commandTimeout: 600

# For high-latency environments
maxRetries: 5
retryDelaySeconds: 3  # 3s → 6s → 12s → 24s → 48s
```

## Dependency Resolution (Programmability Objects)

**Automatic Cross-Type Dependency Handling**:
- Functions, Views, and Stored Procedures can reference each other in complex ways
- Traditional alphabetical import order fails when dependencies span object types
- Dependency retry logic automatically resolves these references through multiple passes

**Supported Dependency Scenarios**:
- Function → Function (function calls another function)
- View → Function (view uses function in SELECT statement)
- Function → View (function queries a view)
- Stored Procedure → Function/View (procedure uses both)
- Complex chains (Proc → Func → View → Func multi-hop dependencies)

**How It Works**:
1. All programmability objects attempted on first pass
2. Failed scripts (missing dependencies) collected for retry
3. Subsequent passes retry only failed scripts (successful scripts enable others)
4. Early exit if no progress made (prevents infinite loops on real errors)
5. Default 10 retry attempts handles most dependency graphs

**Configuration**:
```yaml
import:
  dependencyRetries:
    enabled: true          # Enable/disable (default: true)
    maxRetries: 10         # Retry attempts (1-10, default: 10)
    objectTypes:           # Object types to retry together
      - Functions          # (default)
      - StoredProcedures   # (default)
      - Views              # (default)
      # Optional additions:
      # - Synonyms
      # - TableTriggers
      # - DatabaseTriggers
```

**Example Scenario**:
```sql
-- Attempt 1 (alphabetical order):
-- [OK] fn_HelperCalculateTax      (no dependencies)
-- [OK] fn_CalculateTotalWithTax    (calls fn_HelperCalculateTax - succeeds)
-- [FAIL] fn_GetOrdersWithTax      (queries vw_OrderTotals - FAILS, view not created yet)
-- [OK] vw_OrderTotals              (calls fn_CalculateTotalWithTax - succeeds)

-- Attempt 2 (retry failed scripts):
-- [OK] fn_GetOrdersWithTax         (queries vw_OrderTotals - NOW SUCCEEDS)

-- Result: All objects imported successfully!
```

**Note**: Security Policies are automatically deferred to execute AFTER all programmability objects, ensuring functions/procedures they reference exist.

## Cross-Platform Support

**FileGroups**: 
- Export uses SQLCMD variables: `$(FG_CURRENT_PATH_FILE)`
- Import detects target OS (Windows/Linux) and builds appropriate paths
- Database-specific file naming prevents conflicts: `{Database}_{FileGroup}.ndf`
- Linux example: `/var/opt/mssql/data/MyDb_Archive.ndf`
- Windows example: `E:\SQLData\MyDb_Archive.ndf`

**Path Separators**: Automatically determined based on target SQL Server OS.

## Technical Notes

### GO Batch Separator Handling

The Import script splits SQL files on `GO` batch separators using regex pattern matching. Supported GO formats:
- Standard: `GO` on its own line
- With spaces: `GO  ` (trailing whitespace)
- With repeat count: `GO 5` (repeat count syntax is accepted but ignored; the batch runs once)
- With comment: `GO -- comment` (inline comment after GO)

**Important**: The regex assumes SMO-generated scripts where GO is never inside quoted strings or block comments. If using manually edited SQL files from other sources, ensure GO statements are properly formatted on separate lines.

## Documentation

- **README.md** (this file): Quick start and parameter reference
- **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)**: Detailed usage instructions, export/import modes, and examples
- **[docs/CONFIG_REFERENCE.md](docs/CONFIG_REFERENCE.md)**: Comprehensive configuration file reference with all properties, types, and examples
- **[docs/SOFTWARE_DESIGN.md](docs/SOFTWARE_DESIGN.md)**: Internal architecture, folder structure, and design decisions
- **[tests/README.md](tests/README.md)**: Integration testing with Docker
- **[.github/copilot-instructions.md](.github/copilot-instructions.md)**: Code style conventions

See [CHANGELOG.md](CHANGELOG.md) for complete release notes.

## Help

View detailed help:
```powershell
Get-Help ./Export-SqlServerSchema.ps1 -Full
Get-Help ./Import-SqlServerSchema.ps1 -Full
```

Validate scripts:
```powershell
./Validate-Scripts.ps1
```

## License

See LICENSE file
