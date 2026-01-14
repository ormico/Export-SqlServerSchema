# SQL Server Database Scripting Toolkit

PowerShell toolkit for exporting and importing SQL Server database schemas with proper dependency ordering, two-mode deployment system, comprehensive object type support, and enterprise-grade reliability features.

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
- FileGroups with SQLCMD variable parameterization
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
| `-Credential` | No | SQL authentication credentials |
| `-TargetSqlVersion` | No | Target SQL version (default: Sql2022) |
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
| `-Credential` | No | SQL authentication credentials |
| `-Force` | No | Skip existing schema check |
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

Two formats supported:

**Simplified Format** (recommended for most scenarios):
```yaml
importMode: Dev  # or Prod
includeData: true

# Reliability settings (optional, defaults shown):
connectionTimeout: 30      # Connection timeout in seconds
commandTimeout: 300        # Command execution timeout in seconds
maxRetries: 3              # Retry attempts for transient failures
retryDelaySeconds: 2       # Initial delay, uses exponential backoff

# Only needed for Prod mode with FileGroups:
fileGroupPathMapping:
  FG_CURRENT: "E:\\SQLData\\Current"
  FG_ARCHIVE: "F:\\SQLArchive\\Archive"
```

**Full Format** (advanced scenarios):
```yaml
import:
  defaultMode: Dev
  productionMode:
    includeFileGroups: true
    includeDatabaseScopedConfigurations: true
    includeExternalDataSources: true
    enableSecurityPolicies: true
    fileGroupPathMapping:
      FG_CURRENT: "E:\\SQLData\\Current"
      FG_ARCHIVE: "F:\\SQLArchive\\Archive"
  developerMode:
    # FileGroup handling strategy (Dev mode only):
    fileGroupStrategy: autoRemap     # 'autoRemap' (default) or 'removeToPrimary'
    includeDatabaseScopedConfigurations: false
```

**FileGroup Strategies** (Developer Mode):
- **`autoRemap`** (default): Imports FileGroups with auto-detected paths
  - Detects SQL Server's default data directory automatically
  - No configuration required
  - Preserves FileGroup structure for accurate testing
- **`removeToPrimary`**: Skips FileGroups entirely
  - All tables/indexes/partitions moved to PRIMARY
  - Simplest setup, but loses FileGroup structure

See `tests/test-dev-config.yml` and `tests/test-prod-config.yml` for examples.

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
- **EXPORT_IMPORT_STRATEGY.md**: Comprehensive design documentation
- **MISSING_OBJECTS_ANALYSIS.md**: SQL Server object type coverage analysis
- **tests/README.md**: Integration testing with Docker
- **.github/copilot-instructions.md**: Code style conventions

See [CHANGELOG.md](CHANGELOG.md) for complete release notes and [EXPORT_IMPORT_STRATEGY.md](EXPORT_IMPORT_STRATEGY.md) for detailed feature documentation.

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
