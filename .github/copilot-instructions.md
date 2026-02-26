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

# WRONG - dot-sourcing the MAIN scripts executes them and triggers mandatory parameter prompts
. './Export-SqlServerSchema.ps1'
pwsh -Command ". './Export-SqlServerSchema.ps1'"

# WRONG - Get-Credential prompts interactively
$cred = Get-Credential
```

**Note**: The "no dot-sourcing" rule applies only to the main scripts that have mandatory parameters. Dedicated helper/library files (e.g., `Common-SqlServerSchema.ps1` per issue #66) designed to be dot-sourced are a different, safe pattern. Do NOT convert shared helper files to `.psm1` modules — `$script:` variables inside a module refer to the module's scope, not the caller's scope, which would silently break all shared-state functions (`Write-Log`, metrics tracking, etc.).

### Testing Internal Functions
To test internal functions WITHOUT triggering mandatory parameters, you CANNOT dot-source.
Instead, run the actual tests or use the scripts with valid parameters:
```powershell
# CORRECT - Run existing test scripts
pwsh -NoProfile -File ./tests/run-integration-test.ps1
pwsh -NoProfile -File ./tests/test-exclude-feature.ps1

# CORRECT - Validate syntax without execution
pwsh -NoProfile -Command "Get-Command './Export-SqlServerSchema.ps1' -Syntax"

# CORRECT - Test internal algorithm in isolation by re-implementing it locally in the test file
# (see test-config-auto-discovery.ps1 for the established pattern)
```

---

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

**Dependency Ordering**: Scripts are exported in 21 numbered folders (01_Schemas → 16_Data) to ensure safe deployment. Foreign keys are separated into separate folders (Tables_PrimaryKey before Tables_ForeignKeys) to avoid circular dependencies during import.

**Object Granularity**: Each programmability object (functions, procedures, views) gets its own file named `{Schema}.{ObjectName}.sql` for Git-friendly version control. Schema-level objects (tables, indexes) are consolidated into numbered files per category.

**Data Import Strategy**: Import-SqlServerSchema temporarily disables FK constraints before data load, then re-enables and validates referential integrity after completion.

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

**Pattern**: Use `-Overrides` hashtable to control SMO ScriptingOptions. Default options are in `New-ScriptingOptions`, merged with overrides. This enables precise control over what gets scripted per object type.

### Error Handling Convention

Both scripts use `$ErrorActionPreference = 'Stop'` at the top, then structured try-catch blocks:

```powershell
try {
    # Main logic
} catch {
    Write-Host "[ERROR] Descriptive message: $_" -ForegroundColor Red
    exit 1
}
```

**Convention**: Always prefix output with `[SUCCESS]`, `[ERROR]`, `[WARNING]`, `[INFO]` for parseable logs. Use colored output for readability.

### Testing Approach

**Two categories of tests:**

1. **Unit/feature tests** (no SQL Server needed): `test-*.ps1` files in `tests/` that test algorithm logic, output messages, and config handling. These should always pass regardless of environment.

2. **Integration tests** (require Docker + SQL Server): `run-integration-test.ps1` and any `test-*.ps1` with a `Requires: SQL Server container running` comment. These need a running SQL Server container.

Test database credentials are in `tests/.env` (SA_PASSWORD=Test@1234). Never commit real credentials.

#### Running Integration Tests — Docker Checklist

Before running integration tests, verify Docker is available and properly configured:

```powershell
# 1. Check Docker is running and in Linux container mode (required for SQL Server)
docker info 2>&1 | Select-String 'OSType'
# Expected: OSType: linux
# If you see 'windows', switch Docker Desktop to Linux containers mode first

# 2. Check if the SQL Server container is already running (avoid redundant docker-compose up)
docker ps --filter "name=sqlserver" --format "{{.Names}} {{.Status}}"
# If a container shows 'Up', skip step 3

# 3. Start the container only if not already running
cd tests && docker-compose up -d

# 4. Run integration tests
pwsh ./run-integration-test.ps1
```

**Critical rules for Docker and parallel sessions:**

- **No test script calls `docker-compose down`** — it is safe to have multiple test sessions running against the same container simultaneously.
- **DO NOT call `docker-compose down`** while any test session may be running; it will cause all in-flight integration tests to fail.
- **`tests/.env` is gitignored** and does NOT exist in worktrees. Copy it from the main repo's `tests/` directory before running integration tests from a worktree: `cp ../../../tests/.env ./tests/.env` (adjust path as needed).
- **Parallel session collision**: Database names (`TestDb`, `TestDb_Dev`, `TestDb_Prod`) are hardcoded. Two parallel worktree sessions running integration tests simultaneously will collide. Avoid concurrent integration test runs until a `$testRunId` suffix strategy is implemented.

## Development Workflows

### Adding New Object Type Export

1. Add folder to `Initialize-OutputDirectory` subdirs array
2. Add export logic to `Export-DatabaseObjects` function
3. Follow the pattern: check if collection exists, script with appropriate options, output success count
4. Update `New-DeploymentManifest` deployment order list
5. Test with: `docker-compose up -d` then run export against TestDb

### Working with SMO Collections

All SMO collections follow this pattern: `$Database.{CollectionName} | Where-Object { -not $_.IsSystemObject }`

**System object filtering**: Essential to exclude built-in SQL Server objects. Some collections (FileGroups, PartitionFunctions) don't have `IsSystemObject` property — omit the filter for those.

**Scriptable collections** (from Database object): Sequences, PartitionFunctions, PartitionSchemes, UserDefinedTypes, Tables, Indexes, ForeignKeys, Triggers, Views, StoredProcedures, UserDefinedFunctions, Synonyms, Schemas, Roles, Users, Certificates, AsymmetricKeys, SymmetricKeys, FullTextCatalogs, Assemblies, etc.

### Import Script Folder Processing Order

Import-SqlServerSchema reads numbered folders in alphabetical order. **Critical**: Folders MUST be processed by number prefix. The `Get-ScriptFiles` function sorts directories by name, ensuring `07_Tables_PrimaryKey` runs before `08_Tables_ForeignKeys` to prevent FK constraint failures.

## Project-Specific Conventions

### File Naming

- **Export scripts**: `{Schema}.{ObjectName}.sql` for objects, `001_{Type}.sql` for grouped objects
- **Output folders**: `{ServerName}_{DatabaseName}_{YYYYMMDD_HHMMSS}/` with timestamp
- **Test files**: `test-schema.sql` creates fixtures, `run-integration-test.ps1` orchestrates

### Parameter Conventions

Both main scripts accept:
- `-Server` (optional if provided via `-ServerFromEnv` or config `connection.serverFromEnv`) and `-Database` (required)
- `-Credential` for SQL auth, or `-UsernameFromEnv`/`-PasswordFromEnv` for env var credentials (optional, defaults to Windows auth)
- `-TrustServerCertificate` for containers with self-signed certificates
- `-IncludeData` switch for data export/import
- Export uses `-OutputPath`, Import uses `-SourcePath`

### Version Targeting

`-TargetSqlVersion` parameter maps to SMO SqlServerVersion enum (Sql2012/2014/2016/2017/2019/2022). Affects syntax in generated scripts (e.g., newer features get excluded for older targets).

## Known Constraints & Workarounds

### Always Encrypted Keys

ColumnMasterKeys and ColumnEncryptionKeys are fully supported. Unlike traditional encryption objects (DMK, symmetric keys, certificates), Always Encrypted keys don't require secrets during import — CMKs store only metadata (key store provider + path), CEKs store an encrypted blob decryptable only by the external CMK.

### Data Export Limitations

Large tables (millions of rows) may cause memory issues with INSERT statement generation. Consider BCP or SSIS for production-scale data.

### Cross-Database References

Synonyms and views referencing other databases will script with their original references and may need manual adjustment in target environments.

## Debugging Tips

- Use `-Verbose` on Import-SqlServerSchema to see full SQL script execution
- Check `_DEPLOYMENT_README.md` in export folder for deployment order documentation
- SQL errors during import often indicate missing dependencies — verify folder processing order
- For SMO scripting issues, inspect `$Scripter.Options` properties in PowerShell debugger

## References

- **Main docs**: README.md (usage examples, parameters)
- **Testing**: tests/README.md (Docker setup, integration tests)
- **SMO docs**: https://learn.microsoft.com/en-us/sql/relational-databases/server-management-objects-smo/
