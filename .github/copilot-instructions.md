# Copilot Instructions for Export-SqlServerSchema

## CRITICAL: Script Invocation Quick Reference

**COPY-PASTE THESE PATTERNS** when running Export/Import scripts. Do NOT omit parameters or use Get-Credential.

### Export Script - Required Parameters
```powershell
# Minimum required (Windows Auth)
& ./Export-SqlServerSchema.ps1 -Server 'localhost' -Database 'MyDb' -OutputPath './output'

# With SQL Auth (test environment)
$securePass = ConvertTo-SecureString 'Test@1234' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('sa', $securePass)
& ./Export-SqlServerSchema.ps1 -Server 'localhost' -Database 'TestDb' -OutputPath './output' -Credential $cred
```

### Import Script - Required Parameters
```powershell
# Minimum required (Windows Auth)
& ./Import-SqlServerSchema.ps1 -Server 'localhost' -Database 'TargetDb' -SourcePath './exported_scripts'

# With SQL Auth (test environment)
$securePass = ConvertTo-SecureString 'Test@1234' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('sa', $securePass)
& ./Import-SqlServerSchema.ps1 -Server 'localhost' -Database 'TargetDb' -SourcePath './exported_scripts' -Credential $cred
```

### Test Environment Values (from tests/.env)
- **Server**: `localhost` or `localhost,1433`
- **Password**: `Test@1234`
- **Username**: `sa`

### NEVER DO THIS (causes blocking prompts)
```powershell
# WRONG - missing mandatory parameters, will prompt and block
& ./Export-SqlServerSchema.ps1
& ./Import-SqlServerSchema.ps1
pwsh -Command "& { . './Export-SqlServerSchema.ps1' }"

# WRONG - dot-sourcing EXECUTES the script and triggers mandatory parameter prompts
. './Export-SqlServerSchema.ps1'
pwsh -Command ". './Export-SqlServerSchema.ps1'"

# WRONG - Get-Credential prompts interactively
$cred = Get-Credential
```

### Testing Internal Functions
To test internal functions WITHOUT triggering mandatory parameters, you CANNOT dot-source.
Instead, run the actual tests or use the scripts with valid parameters:
```powershell
# CORRECT - Run existing test scripts
pwsh -NoProfile -File ./tests/run-integration-test.ps1
pwsh -NoProfile -File ./tests/test-exclude-feature.ps1

# CORRECT - Validate syntax without execution
pwsh -NoProfile -Command "Get-Command './Export-SqlServerSchema.ps1' -Syntax"
```

---

## Active Development Tasks

**Parallel Export Feature**: If implementing parallel export, read these documents first:
1. `docs/PARALLEL_EXPORT_DESIGN.md` - Architecture and decisions
2. `docs/PARALLEL_EXPORT_IMPLEMENTATION.md` - Step-by-step implementation guide
3. `.github/copilot-parallel-export.md` - Quick reference for AI assistants

**Incremental Export Feature** (after parallel): See `docs/INCREMENTAL_EXPORT_FEASIBILITY.md`

## CRITICAL: No Shortcuts Policy

**NEVER** take shortcuts, produce "streamlined" or "condensed" versions, or compromise features without explicit user approval. This includes:

- ❌ Skipping object types in implementations
- ❌ Omitting edge cases or error handling
- ❌ Simplifying complex logic that is required by design
- ❌ Leaving "TODO" comments instead of implementing features
- ❌ Creating placeholder functions without full implementation

**If implementation is large:**
- ✅ Break into smaller, well-designed helper functions
- ✅ Implement incrementally but completely
- ✅ Ask user for guidance on approach BEFORE starting
- ✅ Follow design documents exactly as written

**When in doubt:** Ask the user. Don't assume you can skip things.

---

## Code Style Conventions

**Full Style Guide**: See `.github/instructions/powershell.instructions.md` for comprehensive PowerShell coding standards.

**Key Rules**:
- **No Unicode/Emojis**: Use `[SUCCESS]`, `[ERROR]`, `[WARNING]`, `[INFO]` prefixes instead
- **Console Output**: Use `Write-Host` with colored prefixes, not `Write-Output`
- **Function Names**: Use approved PowerShell verbs (`Get-`, `Set-`, `New-`, `Export-`, etc.)
- **Parameters**: One per line with `HelpMessage`, use `ValidateSet` for enums
- **Script State**: Use `$script:VariableName` for cross-function state
- **Error Handling**: `$ErrorActionPreference = 'Stop'` with try/catch blocks

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

ColumnMasterKeys and ColumnEncryptionKeys are now fully supported for export and import. Unlike traditional encryption objects (DMK, symmetric keys, certificates), Always Encrypted keys don't require secrets during import because:
- **CMK (Column Master Key)**: Only stores metadata (key store provider name + key path). The actual key is in an external store (Azure Key Vault, Windows Certificate Store, HSM).
- **CEK (Column Encryption Key)**: Stores an encrypted blob that can only be decrypted by the external CMK.

The T-SQL scripts exported by SMO are complete and can be imported directly without any password/secret configuration.

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
