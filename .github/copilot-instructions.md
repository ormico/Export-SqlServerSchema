# Copilot Instructions for Export-SqlServerSchema

## Code Style Conventions

**No Unicode Glyphs or Emojis**: Never use Unicode glyphs, emojis, or decorative symbols in documentation, code, or output messages. Use text-based formatting instead:
- Use `[SUCCESS]`, `[ERROR]`, `[WARNING]`, `[INFO]` prefixes for console output (see Export-SqlServerSchema.ps1 lines 288+)
- Use bullet points (`-`), numbered lists, and markdown headers (`###`) for structure
- Use words like "Production", "Developer", "CI/CD" instead of colored circle emojis (🔵🟢🟡)
- Use text labels like "ALREADY EXPORTED", "RECOMMENDED", "OPTIONAL" instead of checkmarks/crosses (✅❌⚠️)

**Rationale**: Text-based formatting ensures compatibility across all terminals, editors, and platforms. MISSING_OBJECTS_ANALYSIS.md currently violates this convention with emoji usage and should be refactored.

## Project Architecture

This is a **PowerShell 7+ toolkit** for exporting/importing SQL Server database schemas using SQL Server Management Objects (SMO). The core architecture uses:

- **Export-SqlServerSchema.ps1**: Exports database objects to individual SQL files in dependency order (21 numbered folders)
- **Import-SqlServerSchema.ps1**: Applies exported scripts in correct order with FK constraint management
- **SMO (SqlServer module)**: Microsoft's official library for SQL Server scripting via .NET

### Critical Design Decisions

**Dependency Ordering**: Scripts are exported in 21 numbered folders (01_Schemas → 16_Data) to ensure safe deployment. Foreign keys are separated (07_Tables_PrimaryKey, 08_Tables_ForeignKeys) to avoid circular dependencies during import.

**Object Granularity**: Each programmability object (functions, procedures, views) gets its own file named `{Schema}.{ObjectName}.sql` for Git-friendly version control. Schema-level objects (tables, indexes) are consolidated into numbered files per category.

**Data Import Strategy**: Import-SqlServerSchema temporarily disables FK constraints before data load, then re-enables and validates referential integrity after completion (see `Invoke-SqlScript` function lines 264-340).

## Key Code Patterns

### SMO Scripter Configuration (Export-SqlServerSchema.ps1)

```powershell
# New-ScriptingOptions accepts a hashtable of overrides
$opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
    DriAll = $false
    DriPrimaryKey = $true  # Only PKs, not FKs
    Indexes = $false
}
```

**Pattern**: Use `-Overrides` hashtable to control SMO ScriptingOptions. Default options are in `New-ScriptingOptions` (lines 215-267), merged with overrides. This enables precise control over what gets scripted per object type.

### Error Handling Convention

Both scripts use `$ErrorActionPreference = 'Stop'` at the top, then structured try-catch blocks with detailed error messages:

```powershell
try {
    # Main logic
} catch {
    Write-Host "[ERROR] Descriptive message: $_" -ForegroundColor Red
    exit 1
}
```

**Convention**: Always prefix output with `[SUCCESS]`, `[ERROR]`, `[WARNING]` for parseable logs. Use colored output for readability.

### Testing Approach

Integration tests use **Docker Compose** with SQL Server 2022 in `tests/`. The test workflow (run-integration-test.ps1):

1. Creates test database with complex schema (sequences, partitions, triggers, RLS)
2. Exports using Export-SqlServerSchema.ps1
3. Imports to new database using Import-SqlServerSchema.ps1
4. Validates object counts, data integrity, FK constraints

**Run tests**: `cd tests && docker-compose up -d && pwsh ./run-integration-test.ps1`

Test database credentials are in `tests/.env` (SA_PASSWORD=Test@1234). Never commit real credentials.

## Development Workflows

### Adding New Object Type Export

1. Add folder to `Initialize-OutputDirectory` subdirs array (line 158+)
2. Add export logic to `Export-DatabaseObjects` function (~line 271-683)
3. Follow the pattern: check if collection exists, script with appropriate options, output success count
4. Update `New-DeploymentManifest` deployment order list (line 770+)
5. Test with: `docker-compose up -d` then run export against TestDb

**Example** (see lines 310-324 for Sequences):
```powershell
$sequences = @($Database.Sequences | Where-Object { -not $_.IsSystemObject })
if ($sequences.Count -gt 0) {
    $opts = New-ScriptingOptions -TargetVersion $TargetVersion
    $opts.FileName = Join-Path $OutputDir '02_Sequences' '001_Sequences.sql'
    $Scripter.Options = $opts
    $Scripter.EnumScript($sequences)
    Write-Output "  [SUCCESS] Exported $($sequences.Count) sequence(s)"
}
```

### Working with SMO Collections

All SMO collections follow this pattern: `$Database.{CollectionName} | Where-Object { -not $_.IsSystemObject }`

**System object filtering**: Essential to exclude built-in SQL Server objects. Some collections (FileGroups, PartitionFunctions) don't have `IsSystemObject` property—exclude filter for those.

**Scriptable collections** (from Database object): Sequences, PartitionFunctions, PartitionSchemes, UserDefinedTypes, Tables, Indexes, ForeignKeys, Triggers, Views, StoredProcedures, UserDefinedFunctions, Synonyms, Schemas, Roles, Users, Certificates, AsymmetricKeys, SymmetricKeys, FullTextCatalogs, Assemblies, etc.

### Import Script Folder Processing Order

Import-SqlServerSchema reads folders in `Get-ScriptFiles` (line 343+). **Critical**: Folders MUST be processed alphabetically by number prefix. The function sorts by name, then reads all .sql files within each folder:

```powershell
$scriptDirs = Get-ChildItem $SourcePath -Directory | 
    Where-Object { $_.Name -match '^\d{2}_' } | 
    Sort-Object Name
```

**Why numbered prefixes**: Ensures 07_Tables_PrimaryKey runs before 08_Tables_ForeignKeys, preventing FK constraint failures.

## Project-Specific Conventions

### File Naming

- **Export scripts**: `{Schema}.{ObjectName}.sql` for objects, `001_{Type}.sql` for grouped objects
- **Output folders**: `{ServerName}_{DatabaseName}_{YYYYMMDD_HHMMSS}/` with timestamp
- **Test files**: `test-schema.sql` creates fixtures, `run-integration-test.ps1` orchestrates

### Parameter Conventions

Both main scripts accept:
- `-Server` and `-Database` (required)
- `-Credential` for SQL auth (optional, defaults to Windows auth)
- `-IncludeData` switch for data export/import
- Export uses `-OutputPath`, Import uses `-SourcePath`

### Version Targeting

`-TargetSqlVersion` parameter maps to SMO SqlServerVersion enum (Sql2012/2014/2016/2017/2019/2022). Affects syntax in generated scripts (e.g., newer features get excluded for older targets).

## Critical Integration Points

### SMO Dependency

The SqlServer PowerShell module must be installed: `Install-Module SqlServer -Scope CurrentUser`

**Compatibility**: Requires PowerShell 7.0+. Scripts check version at startup (`Test-Dependencies` function).

### Authentication

Both scripts support:
- **Windows Auth**: Default if no `-Credential` specified
- **SQL Auth**: Pass PSCredential object: `Get-Credential` or construct programmatically

**Connection pattern** (used in both scripts):
```powershell
$serverConn = [Microsoft.SqlServer.Management.Common.ServerConnection]::new($Server)
if ($Credential) {
    $serverConn.LoginSecure = $false
    $serverConn.Login = $Credential.UserName
    $serverConn.SecurePassword = $Credential.Password
}
$serverConn.Connect()
```

## Known Constraints & Workarounds

### FileGroups & Physical Storage

Currently **not exported** (see MISSING_OBJECTS_ANALYSIS.md). FileGroups are environment-specific and should be parameterized, not hardcoded. Future enhancement planned with `-IncludeFileGroups` switch.

### Always Encrypted Keys

ColumnMasterKeys and ColumnEncryptionKeys are intentionally skipped—they require certificate management outside the database and can't be safely exported as T-SQL scripts.

### Data Export Limitations

Large tables (millions of rows) may cause memory issues with INSERT statement generation. Consider exporting data separately using BCP or SSIS for production databases.

### Cross-Database References

Synonyms and views referencing other databases will script with their original references. These may need manual adjustment in target environments.

## Debugging Tips

- Use `-Verbose` on Import-SqlServerSchema to see full SQL script execution
- Check `_DEPLOYMENT_README.md` in export folder for deployment order documentation
- SQL errors during import often indicate missing dependencies—verify folder processing order
- For SMO scripting issues, inspect `$Scripter.Options` properties in PowerShell debugger

## References

- **Main docs**: README.md (usage examples, parameters)
- **Testing**: tests/README.md (Docker setup, integration tests)
- **Missing features**: MISSING_OBJECTS_ANALYSIS.md (future enhancements, best practices)
- **SMO docs**: https://learn.microsoft.com/en-us/sql/relational-databases/server-management-objects-smo/
