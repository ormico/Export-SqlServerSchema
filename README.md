# SQL Server Database Scripting Toolkit

PowerShell toolkit for exporting and importing SQL Server database schemas with proper dependency ordering, two-mode deployment system, and comprehensive object type support.

**Version**: 1.1.0  
**Released**: November 10, 2025  
**Status**: Production Ready

## Quick Start

### Prerequisites

- PowerShell 7.0+
- SQL Server 2012+ or Azure SQL Database
- SQL Server Management Objects (SMO): `Install-Module SqlServer -Scope CurrentUser`
- PowerShell YAML module (optional): `Install-Module powershell-yaml -Scope CurrentUser`

### Export Database

```powershell
# Install required modules
Install-Module SqlServer -Scope CurrentUser
Install-Module powershell-yaml -Scope CurrentUser  # Optional, for YAML config support

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
| `-CommandTimeout` | No | Timeout in seconds (default: 300) |

## Import Modes Explained

**Developer Mode (default)**:
- Skips FileGroups (objects remapped to PRIMARY)
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

## YAML Configuration Files

Two formats supported:

**Simplified Format** (recommended for most scenarios):
```yaml
importMode: Dev  # or Prod
includeData: true

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
    includeFileGroups: false
    includeDatabaseScopedConfigurations: false
```

See `tests/test-dev-config.yml` and `tests/test-prod-config.yml` for examples.

## Foreign Key Constraint Management

When importing data, the Import script automatically:
1. Disables all foreign key constraints
2. Imports data in any order (no dependency sorting needed)
3. Re-enables all foreign key constraints
4. Validates referential integrity

This eliminates data import dependency errors and ensures data integrity.

## Cross-Platform Support

**FileGroups**: 
- Export uses SQLCMD variables: `$(FG_CURRENT_PATH_FILE)`
- Import detects target OS (Windows/Linux) and builds appropriate paths
- Database-specific file naming prevents conflicts: `{Database}_{FileGroup}.ndf`
- Linux example: `/var/opt/mssql/data/MyDb_Archive.ndf`
- Windows example: `E:\SQLData\MyDb_Archive.ndf`

**Path Separators**: Automatically determined based on target SQL Server OS.

## Documentation

- **README.md** (this file): Quick start and parameter reference
- **EXPORT_IMPORT_STRATEGY.md**: Comprehensive design documentation
- **MISSING_OBJECTS_ANALYSIS.md**: SQL Server object type coverage analysis
- **tests/README.md**: Integration testing with Docker
- **.github/copilot-instructions.md**: Code style conventions

## Project Status

**Version 1.1.0** (November 10, 2025)

All features complete and production-ready:
- ✅ YAML configuration system with JSON Schema validation
- ✅ 10+ new object types (FileGroups, DB Configs, Security Policies, etc.)
- ✅ Two-mode import system (Dev/Prod) with intelligent defaults
- ✅ Cross-platform FileGroups with SQLCMD variables
- ✅ Comprehensive completion summaries
- ✅ Full integration test coverage (ALL TESTS PASSED)

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
