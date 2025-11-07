# SQL Server Database Scripting Toolkit

PowerShell toolkit for exporting and importing SQL Server database schemas with proper dependency ordering and foreign key constraint management.

## Quick Start

### Prerequisites

- PowerShell 7.0+
- SQL Server 2012+ or Azure SQL Database
- SQL Server Management Objects (SMO): `Install-Module SqlServer -Scope CurrentUser`

### Export Database

```powershell
# Install SMO
Install-Module SqlServer -Scope CurrentUser

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
# Import schema to new database
./Import-SqlServerSchema.ps1 -Server "localhost" -Database "NewDatabase" `
    -SourcePath "./DbScripts/localhost_MyDatabase_TIMESTAMP" -CreateDatabase

# Import with data
./Import-SqlServerSchema.ps1 -Server "localhost" -Database "NewDatabase" `
    -SourcePath "./DbScripts/localhost_MyDatabase_TIMESTAMP" -IncludeData -CreateDatabase
```

## Key Features

**Export-SqlServerSchema.ps1**
- Exports schema in proper dependency order
- Individual files per object (easy version control)
- Optional data export with INSERT statements
- Supports SQL Server 2012-2022, Azure SQL
- Cross-platform (Windows, Linux, macOS)

**Import-SqlServerSchema.ps1**
- Applies scripts in correct dependency order
- Automatic foreign key constraint management for data imports
- Creates database if needed
- Configurable error handling and timeouts
- Validates referential integrity after data import

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
    01_Schemas/                   # Database schemas
    02_Types/                     # User-defined types
    03_Tables_PrimaryKey/         # Tables with primary keys
    04_Tables_ForeignKeys/        # Foreign key constraints
    05_Indexes/                   # Indexes
    06_Defaults/                  # Default constraints
    07_Rules/                     # Rule constraints
    08_Programmability/           # Functions, procedures, triggers, views
    09_Synonyms/                  # Synonyms
    10_FullTextSearch/            # Full-text catalogs
    11_Security/                  # Keys, certificates, roles
    12_Data/                      # Optional data INSERT scripts
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
| `-CreateDatabase` | No | Create database if it doesn't exist |
| `-IncludeData` | No | Import data from 12_Data folder |
| `-Credential` | No | SQL authentication credentials |
| `-Force` | No | Skip existing schema check |
| `-ContinueOnError` | No | Continue on script errors |
| `-CommandTimeout` | No | Timeout in seconds (default: 300) |

## Foreign Key Constraint Management

When importing data, the Import script automatically:
1. Disables all foreign key constraints
2. Imports data in any order (no dependency sorting needed)
3. Re-enables all foreign key constraints
4. Validates referential integrity

This eliminates data import dependency errors and ensures data integrity.

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
