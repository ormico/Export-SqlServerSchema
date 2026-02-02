# Changelog

All notable changes to Export-SqlServerSchema will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.8] - 2026-02-02

### Fixed

**CMK Fallback Scanning Used Wrong Table Folder Paths**
- Fixed `Get-RequiredEncryptionSecrets` fallback table scanning to use correct folder paths
- Was scanning `07_Tables/` (which is the User-Defined Types folder) instead of `09_Tables_PrimaryKey/` and `10_Tables_ForeignKeys/`
- Old exports without metadata that use `ENCRYPTED WITH` clauses on table columns are now correctly detected during import
- Updated `test-encryption-fallback-scan.ps1` to use correct `09_Tables_PrimaryKey` folder in test fixtures

---

## [1.7.7] - 2026-02-02

### Changed
**Added CONFIG_REFERENCE.md to Release**

---

## [1.7.6] - 2026-01-30

### Added

**Always Encrypted Support (Column Master Keys & Column Encryption Keys)**
- Export now scripts `ColumnMasterKeys` and `ColumnEncryptionKeys` to `01_Security/` folder
- CMK exported to `004_ColumnMasterKeys.sql`, CEK to `005_ColumnEncryptionKeys.sql`
- Existing security file numbers adjusted: Roles→`006`, ApplicationRoles→`007`, Users→`008`
- New object types `ColumnMasterKeys` and `ColumnEncryptionKeys` added to `-IncludeObjectTypes` and `-ExcludeObjectTypes` parameters
- Encryption metadata detection includes CMK/CEK counts in `_export_metadata.json`
- Import fallback scanner detects CMK/CEK in SQL files for older exports
- `-ShowRequiredSecrets` now displays Always Encrypted keys with info that no secrets are needed
- **Note**: Unlike traditional encryption (DMK, symmetric keys), Always Encrypted keys don't require secrets during import because the actual keys are stored externally (Azure Key Vault, Windows Certificate Store, HSM)

**Fallback Scanning for Old Exports**
- Comprehensive SQL file scanning now reads ALL `.sql` files in `01_Security/` folder
- Detects encryption objects regardless of filename (supports non-standard naming)
- Scans table scripts in `09_Tables_PrimaryKey/` and `10_Tables_ForeignKeys/` for `ENCRYPTED WITH` clauses to infer CEK usage
- New automated test suite: `tests/test-encryption-fallback-scan.ps1` with 9 test cases

### Changed

- **Security file numbering**: Roles moved from `004_` to `006_`, ApplicationRoles from `005_` to `007_`, Users from `006_` to `008_` to accommodate new CMK/CEK files. Old exports are unaffected (import processes all `.sql` files by alphabetical order regardless of numbering).

**Documentation Updates**
- Updated README.md parallel/sequential export performance numbers to reflect v1.6.0 results
  - Sequential: 93.30s → 91s
  - Parallel: 97.58s → 39s (2.3x faster than sequential)
  - Changed from "5% overhead" narrative to "2.3x speedup" to accurately reflect parallel performance improvement
- Added "50K rows" to test database descriptions in README.md for consistency with CHANGELOG

### Fixed

**Encryption Secrets Fallback Scanner**
- Fixed `$matches` hashtable piping bug in symmetric key scanner
- Now uses `[regex]::Matches()` to properly find all symmetric keys in each file
- Added DMK inference for old exports without metadata:
  - Detects `ENCRYPTION BY MASTER KEY` in symmetric key files
  - Detects certificates with `WITH PRIVATE KEY` but no `ENCRYPTION BY PASSWORD` (DMK-encrypted)
- Prevents false negatives when importing old exports that require Database Master Key

**Code Documentation**
- Added comments explaining why CMK/CEK don't filter by `IsSystemObject` (property doesn't exist on these SMO types)
- Updated `Get-EncryptionObjectsMetadata` function documentation to describe two categories:
  - PASSWORD-REQUIRING: DMK, symmetric keys, asymmetric keys, certificates, app roles
  - ALWAYS ENCRYPTED: CMK/CEK (no secrets needed, keys stored externally)

---

## [1.7.4] - 2026-01-29

### Added

**Encryption Secrets Discovery**
- Export now detects encryption objects and stores them in `_export_metadata.json` (version 1.1)
- Captured objects: Database Master Key, symmetric keys, asymmetric keys, certificates, application roles
- New `-ShowRequiredSecrets` switch for Import-SqlServerSchema.ps1
- Displays all encryption objects required for import with a ready-to-use YAML configuration template
- Falls back to scanning SQL files for older exports without metadata
- Example usage:
  ```powershell
  ./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb `
      -SourcePath ".\exports\MyDb_20260129" -ShowRequiredSecrets
  ```
- Enhanced error messages now include YAML config snippets when encryption secrets are missing

### Changed

- Export metadata version bumped from "1.0" to "1.1" to include encryption object detection

---

## [1.7.3] - 2026-01-28

### Added

**Strip FILESTREAM for Linux/Container Targets (Export)**
- New `export.stripFilestream` config option for Export-SqlServerSchema.ps1
- Removes FILESTREAM features at export time for Linux/container deployment targets
- When enabled, transformations applied to exported SQL files:
  - Removes `FILESTREAM_ON [FileGroupName]` clauses entirely
  - Converts `VARBINARY(MAX) FILESTREAM` columns to regular `VARBINARY(MAX)`
  - Removes FILESTREAM FileGroup blocks from FileGroup scripts
- Example config:
  ```yaml
  export:
    stripFilestream: true
  ```
- Display shows `[ENABLED] FILESTREAM stripping` during export when active
- Complementary to import-time stripping - use one or the other

**Strip FILESTREAM for Linux/Container Targets (Import)**
- New `-StripFilestream` parameter for Import-SqlServerSchema.ps1
- New `stripFilestream` config option in developerMode/productionMode settings
- FILESTREAM is Windows-only (requires NTFS filesystem integration)
- When enabled, transformations applied during import:
  - Removes `FILESTREAM_ON [FileGroupName]` clauses entirely
  - Converts `VARBINARY(MAX) FILESTREAM` columns to regular `VARBINARY(MAX)`
  - Skips FILESTREAM FileGroup creation
- Example usage:
  ```powershell
  # Command-line
  ./Import-SqlServerSchema.ps1 -Server localhost -Database MyDb -SourcePath ./export -StripFilestream
  ```
  ```yaml
  # Config file
  import:
    developerMode:
      stripFilestream: true
  ```
- Command-line parameter overrides config file setting
- Default: `false` (FILESTREAM features preserved)

### Fixed

**Export Progress Messages Now Visible**
- Fixed issue where `Export-DatabaseObjects` progress messages were hidden during export
- Messages like "Exporting Tables...", "Found X table(s)", and summary counts now display correctly
- Root cause: `Write-Output` was captured when function return value was assigned to a variable
- Solution: Use script-scoped metrics (`$script:ExportFunctionMetrics`) and convert to `Write-Host` for user-facing output
- Colorized output: SUCCESS (green), WARNING (yellow), INFO (gray), errors (red)

---

## [1.7.2] - 2026-01-28

### Added

**Schema-Based Import Exclusion**
- New `-ExcludeSchemas` parameter for Import-SqlServerSchema.ps1
- Filters scripts by filename prefix (e.g., `cdc.fn_get_changes.sql` excluded when `cdc` in list)
- Supports both command-line parameter and YAML config file:
  ```yaml
  import:
    excludeSchemas:
      - cdc
      - staging
  ```
- Command-line parameter overrides config file setting
- Useful for excluding CDC schema objects, staging tables, or temp schemas during import

**Convert Login-Mapped Users to Contained Users**
- New `convertLoginsToContained` option in developerMode/productionMode settings
- Transforms `FOR LOGIN [loginname]` to `WITHOUT LOGIN` during import
- Allows user creation without requiring server-level logins to exist
- Preserves users for schema ownership, object permissions, and role membership
- Example config:
  ```yaml
  import:
    developerMode:
      convertLoginsToContained: true
  ```
- Handles all user types:
  - Explicit: `CREATE USER [AppUser] FOR LOGIN [AppUser]` → `CREATE USER [AppUser] WITHOUT LOGIN`
  - Implicit Windows: `CREATE USER [DOMAIN\User]` → `CREATE USER [DOMAIN\User] WITHOUT LOGIN`

### Fixed

**Windows User Detection for Implicit Logins**
- `WindowsUsers` exclusion now handles all CREATE USER forms:
  - `CREATE USER [DOMAIN\User] FOR LOGIN [DOMAIN\User]` (explicit)
  - `CREATE USER [DOMAIN\User] WITH DEFAULT_SCHEMA=[dbo]` (implicit - login name = user name)
  - `CREATE USER [NT SERVICE\SQLSERVERAGENT]` (NT service accounts)
- Previously only detected explicit `FOR LOGIN` syntax
- Detection based on backslash (`\`) in username for Windows principals

---

## [1.7.1] - 2025-01-28

### Added

**Granular User Type Exclusions (Bug Fix #2)**
- New exclusion options for database users by authentication type:
  - `WindowsUsers` - Exclude Windows domain users and groups
  - `SqlUsers` - Exclude SQL Server login-based users
  - `ExternalUsers` - Exclude Azure AD users and groups
  - `CertificateMappedUsers` - Exclude certificate and asymmetric key-mapped users
- Enables cross-platform exports by excluding Windows users that fail on Linux SQL Server
- `DatabaseUsers` still works as umbrella exclusion for all user types
- Example: `excludeObjectTypes: [WindowsUsers]` to export SQL logins only

### Fixed

**removeToPrimary Missing TEXTIMAGE_ON/FILESTREAM_ON (Bug Fix #4)**
- `fileGroupStrategy: removeToPrimary` now correctly remaps `TEXTIMAGE_ON` and `FILESTREAM_ON` clauses
- Previously only `ON [FileGroup]` after closing parenthesis was remapped
- Tables with LOB columns (varchar(max), varbinary(max), xml, etc.) now work correctly

**Memory-Optimized FileGroup Export Syntax (Bug Fix #5)**
- Fixed export of memory-optimized FileGroups to use correct `CONTAINS MEMORY_OPTIMIZED_DATA` syntax
- Previously all non-standard FileGroups were exported with `CONTAINS FILESTREAM`
- Now correctly handles all three FileGroup types: RowsFileGroup, FileStreamDataFileGroup, MemoryOptimizedDataFileGroup

**removeToPrimary with Memory-Optimized Tables (Bug Fix #6)**
- `fileGroupStrategy: removeToPrimary` now creates required memory-optimized FileGroups
- Memory-optimized FileGroups cannot be remapped to PRIMARY (they're required infrastructure)
- Standard and FILESTREAM FileGroups are still skipped as expected

### Improved

**Import Error Reporting (Bug Fix #3)**
- Errors now shown in RED immediately when they occur (not hidden in verbose output)
- Shows actual SQL error message inline, not just script name
- Creates `import_errors_<timestamp>.log` file with full error details
- Final summary lists all failed scripts with their error messages
- Programmability dependency retry failures still use appropriate yellow warnings during retries
- Fixed: Error log is now always written when import fails (even on structural failures or fatal errors)
- Fixed: Structural script failures now properly record errors to the error log before aborting

**SQL Injection Prevention (Bug Fix #7)**
- Added `Get-EscapedSqlIdentifier` function to both Export and Import scripts
- FileGroup names are now escaped when generating ALTER DATABASE statements
- Database names are now escaped when replacing ALTER DATABASE CURRENT (memory-optimized FileGroups)
- Prevents second-order SQL injection via malicious object names containing `]` characters

**removeToPrimary Case Sensitivity (Bug Fix #8)**
- FileGroup remapping regex patterns now use case-insensitive matching for `PRIMARY`
- Handles scripts with `ON [primary]`, `ON [Primary]`, or any other case variant
- SQL Server identifiers are case-insensitive, so the regex should be too

**Parallel Export Schema/All Grouping Fixes (Bug Fix #9)**
- Fixed TableTriggers export to use `04_Triggers` subfolder for all grouping modes (not just single)
- Fixed `UserDefinedType` lookup to try all three UDT collections (CLR types, alias types, table types)
- Previously schema/all modes with mixed UDT types would fail to find alias types like `dbo.PhoneNumber`

---

## [1.7.0] - 2026-01-27

### Changed

**Simplified FileGroup Configuration**
- Replaced confusing `includeFileGroups` boolean with `fileGroupStrategy` setting
- `fileGroupStrategy: autoRemap` (default) - imports FileGroups with auto-detected paths using `SERVERPROPERTY('InstanceDefaultDataPath')`
- `fileGroupStrategy: removeToPrimary` - skips FileGroups (has known limitation with partitioned tables)
- Both Dev and Prod modes now default to `autoRemap`
- Updated config schema, example files, and documentation

### Improved

- **Config Schema Documentation**: Added `importMode` and `includeData` at root level in JSON schema for simplified configuration
- **Config Example Clarity**: Added simplified config examples in `export-import-config.example.yml` showing root-level options
- **Complete CLI/Config Parity**: All command-line parameters now have config file equivalents with safe defaults:
  - Export: `targetSqlVersion` (default: Sql2022), `collectMetrics` (default: false), `export.includeObjectTypes`
  - Import: `import.createDatabase` (default: false), `import.force` (default: false), `import.continueOnError` (default: false), `import.showSql` (default: false), `import.includeObjectTypes`
- **Minimal Config Support**: Empty config files now work correctly; all properties have sensible defaults

### Known Issues

**removeToPrimary FileGroup Strategy Limitation**
- The `fileGroupStrategy: removeToPrimary` option does not work with databases containing partitioned tables
- **Root Cause**: Partition schemes cannot reference PRIMARY directly; they require a valid partition scheme
- **Workaround**: Use `fileGroupStrategy: autoRemap` (the default) which imports FileGroups with auto-detected paths
- **Impact**: Dev mode still works correctly with `autoRemap`; only affects users who explicitly set `removeToPrimary`


## [1.6.0] - 2026-01-27

### Added

**Delta Export Feature (Incremental Export)**
- New `-DeltaFrom` parameter to specify a previous export directory for incremental exports
- Exports only changed/new objects since the previous export, significantly reducing export time for large databases
- Automatic metadata generation (`_export_metadata.json`) on every export for delta support
- Change detection using SQL Server's `sys.objects.modify_date` timestamps
- Smart categorization of objects: Modified, New, Deleted, Unchanged
- "Always export" types for objects without reliable modify dates (FileGroups, Schemas, Security, FKs, Indexes)
- Compatibility validation ensures delta exports use same server, database, and groupBy settings
- Copy unchanged files from previous export to create complete output
- Requires `groupBy: single` mode for object-level granularity

**Parallel Export Feature**
- New `-Parallel` switch enables multi-threaded export using PowerShell runspace pools
- New `-MaxWorkers` parameter controls worker thread count (1-20, default: 5)
- Work queue system distributes export tasks across isolated workers
- **2x faster exports** on large databases with data (84s vs 173s parallel vs sequential)

**FileGroup File Size Defaults**
- New `fileGroupFileSizeDefaults` config to override imported file sizes
- Dev mode uses safe defaults (1 MB initial, 64 MB growth) to prevent disk space issues

### Changed

**Hybrid Architecture Refactoring** (Sequential/Parallel Code Unification)
- Sequential export mode now uses `Build-ParallelWorkQueue` and `Process-ExportWorkItem` (same as parallel mode)
- Eliminated ~2,500 lines of duplicate sequential export code (28% reduction: 8,852 → 6,385 lines)
- Both modes produce identical output, verified with comprehensive integration tests
- Bug fixes now automatically apply to both sequential and parallel modes

### Fixed

- **Sequential TableData Processing**: Fixed "No SMO objects found for work item" errors by filtering `TableData` items from sequential work item processing (handled separately by `Export-TableData`)
- **Export Failure Exit Code**: Export script now exits with code 1 when any schema or data export fails, enabling CI/CD pipelines to detect failures
- **Parallel Index Export**: Fixed duplicate CREATE TABLE statements in index files; now exports individual indexes correctly
- **Path Traversal Prevention**: All Build-WorkItems-* functions sanitize schema/object names with `Get-SafeFileName`
- **Parallel Worker Race Condition**: Directory creation now handles concurrent worker conflicts gracefully
- **Parallel Error Reporting**: `$errorItems` collection now correctly populated from failed work items
- **Parallel Data Export**: Fixed `TableData` handler and `$script:IncludeData` scoping for parallel workers
- **Unified Data Export**: Both sequential and parallel modes now use `Build-WorkItems-Data` for consistent row-count filtering

### Performance Results

Test database: 500 tables, 100 views, 500 procedures, 100 functions, 100 triggers, 2000 indexes, 50K rows

**Schema Only** (no `-IncludeData`, ~2,400 files)

| Metric | v1.4.x Baseline | v1.5.0 | v1.5.1 | v1.6.0 Sequential | v1.6.0 Parallel |
|--------|-----------------|--------|--------|-------------------|-----------------|
| Export | 229s | 144s | 99s | **91s** | **39s** |
| Improvement | -- | 37% | 57% | **60%** | **83%** |

**Key Findings**:
- Sequential schema-only: **60% faster** than v1.4.x baseline (229s → 91s)
- Parallel schema-only: **83% faster** than v1.4.x baseline (229s → 39s), **2.3x faster** than sequential

### Known Issues

**SMO PrefetchObjects Synonym Limitation**
- `Database.PrefetchObjects(typeof(Synonym))` fails on SQL Server 2022/Linux containers
- **Impact**: None — caught and logged; synonyms export correctly via lazy loading

## [1.5.1] - 2026-01-21

### Added

- `.editorconfig` file to enforce repository formatting: UTF-8, final newline, trim trailing whitespace (except Markdown), and sensible indentation for PowerShell, SQL, YAML, JSON and Markdown.
- Performance test report `tests/PERFORMANCE_GROUPBY_REPORT.md` with version comparison tables

### Fixed

**PrefetchObjects Implementation**
- Fixed `Database.PrefetchObjects()` call - was using non-existent array overload `PrefetchObjects(Type[])`, now correctly calls single-Type overload per object type
- Added `Scripter.PrefetchObjects = $true` to enable scripter-level dependency prefetch
- Bulk prefetch now completes successfully in ~5 seconds for Tables, Views, StoredProcedures, UserDefinedFunctions, Schemas, Synonyms
- Export time reduced ~33% vs v1.5.0 (from ~145s to ~96s on test database)
- Total round-trip time reduced **57-65%** vs v1.4.x baseline

### Changed

**Export Performance Optimization**
- Tables collection is now cached once at the beginning of `Export-DatabaseObjects` function and reused across all sections (Tables, ForeignKeys, Indexes, TableTriggers, Data export)
- Eliminates 4 duplicate database calls to enumerate non-system tables
- Reduces SMO overhead and speeds up exports for databases with large table counts
- `Database.PrefetchObjects()` bulk-loads object metadata upfront (SSMS-style optimization)
  - Does NOT require `VIEW DATABASE STATE` privilege — loads same metadata, just in bulk
  - Falls back gracefully to lazy loading if prefetch fails for specific types (e.g., Synonyms on empty database)

**Code Cleanup**
- Removed verbose "PHASE" banners from optimization comments in Export-SqlServerSchema.ps1
- Simplified inline documentation while retaining essential technical details

### Performance Results

Test database: 500 tables, 100 views, 500 procedures, 100 functions, 100 triggers, 2000 indexes, 50K rows

**Single Mode** (one file per object)

| Metric | v1.4.x Baseline | v1.5.0 | v1.5.1 (Current) | Improvement |
|--------|-----------------|--------|------------------|-------------|
| Export | 229s | 144s | **99s** | **57% faster** |
| Import | 82s | 23s | **23s** | **72% faster** |
| **Total** | **311s** | **167s** | **122s** | **61% faster** |

**Schema Mode** (objects grouped by schema)

| Metric | v1.4.x Baseline | v1.5.0 | v1.5.1 (Current) | Improvement |
|--------|-----------------|--------|------------------|-------------|
| Export | 229s | 146s | **96s** | **58% faster** |
| Import | 82s | 15s | **14s** | **83% faster** |
| **Total** | **311s** | **161s** | **110s** | **65% faster** |

**All Mode** (all objects in single files)

| Metric | v1.4.x Baseline | v1.5.0 | v1.5.1 (Current) | Improvement |
|--------|-----------------|--------|------------------|-------------|
| Export | 229s | 148s | **96s** | **58% faster** |
| Import | 82s | 14s | **14s** | **83% faster** |
| **Total** | **311s** | **163s** | **110s** | **65% faster** |

## [1.5.0] - 2026-01-21

### Added

**Selective Object Type Filtering via Command-Line**
- New `-IncludeObjectTypes` parameter for Export script (whitelist mode)
- New `-ExcludeObjectTypes` parameter for Export script (blacklist mode)
- New `-IncludeObjectTypes` parameter for Import script (whitelist mode)
- Granular programmability type filtering: Views, Functions, StoredProcedures filter at subfolder level
- Coarse programmability filtering: "Programmability" imports entire folder
- Command-line parameters override YAML config file settings
- Supports 23 object types for fine-grained control over export/import operations
- Integration tests validate filtering for Tables, Views, Functions, StoredProcedures
- See README.md "Selective Object Type Filtering" section for usage examples

**Multi-Pass Import Support**
- `-Force` flag enables multi-pass import workflows
- First pass imports base structure (Schemas, Tables, Types)
- Subsequent passes add dependent objects (Functions, Views, Procedures)
- Required when database already contains schema objects from previous pass
- Documented in README.md with examples

**Dependency Retry Logic for Programmability Objects**
- Automatic handling of cross-type dependencies in Functions, StoredProcedures, and Views
- Multi-pass retry algorithm executes programmability objects up to 10 times (configurable) to resolve dependencies
- Handles complex dependency scenarios:
  - Function → Function (e.g., function calls another function)
  - View → Function (e.g., view uses function in SELECT)
  - Function → View (e.g., function queries view)
  - Procedure → Function/View (e.g., procedure uses both)
  - Cross-chain dependencies (e.g., Proc → Func → View → Func)
- New `import.dependencyRetries` configuration section in YAML:
  - `enabled`: Enable/disable retry logic (default: `true`)
  - `maxRetries`: Maximum retry attempts (default: `10`, range: 1-10)
  - `objectTypes`: Array of object types to retry together (default: `[Functions, StoredProcedures, Views]`)
  - Optional support for `Synonyms`, `TableTriggers`, `DatabaseTriggers`
- Early exit optimization: stops retrying if no progress made (prevents infinite loops on real errors)
- Security policies deferred to execute AFTER programmability objects (ensures dependencies exist)
- Enhanced error reporting with verbose logging shows which scripts failed and why
- JSON schema validation for new configuration section

**Per-Object-Type File Grouping Feature**
- New `groupByObjectTypes` configuration section in YAML config for fine-grained control over file organization
- Three grouping modes per object type:
  - `single`: One file per object (default, best for Git version control)
  - `schema`: Group objects by schema into numbered files (e.g., 001_dbo.sql, 002_Sales.sql)
  - `all`: All objects of a type in one consolidated file (e.g., 001_AllTables.sql)
- Supports 26 object types with full grouping control:
  - Schema-based objects: Sequences, UserDefinedTypes, XmlSchemaCollections, Tables, ForeignKeys, Indexes, Defaults, Rules, Functions, UserDefinedAggregates, StoredProcedures, Views, Synonyms, TableTriggers
  - Database-level objects: Assemblies, DatabaseTriggers, PartitionFunctions, PartitionSchemes, Schemas, FullTextCatalogs, FullTextStopLists, ExternalDataSources, ExternalFileFormats, SearchPropertyLists, PlanGuides
  - Security objects: DatabaseRoles, DatabaseUsers
- FileGroups remain single consolidated file due to custom scripting requirements (documented limitation)
- New `Get-ObjectGroupingMode` helper function for configuration lookup with defaults
- Import script handles all grouping modes transparently (no changes needed to import logic)
- File organization improves Git workflows while maintaining dependency-ordered import

**SMO Prefetch Security Hardening**
- Updated SMO prefetch to use selective property loading instead of loading all properties
- Avoids `VIEW DATABASE STATE` permission requirement by excluding protected properties:
  - Excluded: IndexSpaceUsed, RowCount, DataSpaceUsed (require elevated permissions)
  - Included: Schema, Name, Owner, CreateDate, DateLastModified, IsSystemObject, FileGroup, etc.
- Maintains performance optimization by prefetching safe metadata properties
- Graceful fallback for properties that don't exist on older SQL Server versions
- Works for users with standard database permissions (no elevated privileges needed)

### Changed

**Export Folder Structure**
- Re-ordered object type folders for improved dependency handling and logical grouping
- Moved Security export folder to run first in dependency order (`19_Security` → `01_Security`) so security objects (roles, users, certificates) are created before schemas and other objects that require permissions
- All remaining export folders were renumbered accordingly
- Folder numbering updated to accommodate new object types and grouping features
- Import script processes folders alphabetically by number prefix (ensures correct deployment order)

**Configuration Examples**
- Updated `export-import-config.example.yml` with comprehensive grouping examples and dependency retry settings
- Documented FileGroups limitation (always single file due to custom scripting)
- Added examples for all 26 grouping-supported object types with dependency retry configuration
- Explained cross-type dependency scenarios (Function calls View, Proc queries Function, etc.)

**Test Coverage**
- Created dedicated grouping test configs: `test-groupby-single.yml`, `test-groupby-schema.yml`, `test-groupby-all.yml`
- Updated test configs to validate all 26 object types with grouping feature
- Performance test script (`run-perf-test.ps1`) now supports `-ExportConfigYaml` parameter for testing different groupBy modes
- Performance test script auto-cleans existing PerfTestDb before each run
- **Note**: Integration tests (`run-integration-test.ps1`) use default `single` grouping mode via `test-export-config.yml`
- GroupBy `schema` and `all` modes are validated through performance testing with dedicated configs
- **Added cross-dependency test cases** to validate retry logic:
  - 8 new test objects with intentional cross-type dependencies
  - Function → Function: `fn_CalculateTotalWithTax` calls `fn_HelperCalculateTax`
  - View → Function: `vw_OrderTotalsWithTax` uses `fn_CalculateTotalWithTax`
  - Function → View: `fn_GetCustomerOrdersWithTax` queries `vw_OrderTotalsWithTax`
  - Procedure → Function/View: `usp_GetCustomerSummary` uses both
  - View → View: `vw_RecentOrderSummary` queries `vw_OrderTotalsWithTax`
  - Function → View (chained): `fn_GetTopCustomers` queries `vw_RecentOrderSummary`
  - Procedure → Procedure: `usp_ProcessCustomerOrder` calls other procedures
  - Synonym → View: `OrderSummaries` references `vw_RecentOrderSummary`
- All integration tests pass with retry logic validating multi-pass dependency resolution

### Fixed
- SMO prefetch no longer triggers permission errors for users without `VIEW DATABASE STATE` privilege
- **Programmability objects with cross-type dependencies now import successfully** without manual intervention
- **Security policies execute after functions/procedures** they depend on, preventing import failures
- Error messages during dependency retry are now logged verbosely instead of terminating import prematurely
- **Critical: AppendToFile bug in schema/all grouping modes** - SMO's `EnumScript()` method defaults to `AppendToFile=false`, causing files to be overwritten on each call. Fixed 39 code sections to properly append objects when using `groupBy: schema` or `groupBy: all` modes. Without this fix, only the last object in each group was saved to the output file.

### Performance

**GroupBy Mode Performance Comparison** (500 tables, 100 views, 500 procs, 100 funcs, 100 triggers, 2000 indexes, 50K rows)

| GroupBy Mode | Export (s) | Files | Import (s) | Total (s) | vs Baseline |
|--------------|------------|-------|------------|-----------|-------------|
| single       | 231.33     | 2900  | 22.62      | 253.95    | 19% faster  |
| schema       | 224.78     | 601   | 14.34      | 239.13    | 23% faster  |
| all          | 215.42     | 529   | 11.29      | 226.72    | 27% faster  |
| *Baseline*   | *207.86*   | *2897*| *104.23*   | *312.09*  | --          |

*Baseline: Previous version with unoptimized import, single mode only*

**Key Findings**:
- **Import time improved 78-89%** due to dependency retry optimization and fewer files to process
- **`groupBy: all` is 50% faster import** than `single` mode (11s vs 23s)
- Export time slightly increased due to additional grouping logic, but import gains far outweigh this
- Fewer files = faster import due to reduced file I/O overhead

### Breaking Changes

**IMPORTANT: Folder Order Change**
- **Folder numbering has changed** in v2.0.0 to support new object types and grouping features
- **Old exports (v1.x) may not import correctly** with the new import script due to different folder processing order
- **Action Required**: Re-export databases using v2.0.0 Export-SqlServerSchema.ps1 before importing
- Import script processes folders by alphabetical order of their number prefix (00_, 01_, 02_, etc.)
- If folder numbers changed between versions, dependency ordering may be incorrect

**Migration from v1.x**

```powershell
# 1. Re-export your database with v2.0.0
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb

# 2. Optional: Configure grouping modes in YAML config
# See export-import-config.example.yml for examples

# 3. Import using new export
./Import-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -SourcePath ./exports/MyDb -ImportMode Prod
```

**Backward Compatibility Note**
- Import script can still process v1.x exports if folder numbers didn't change
- Safest approach: Always re-export with matching version of Export-SqlServerSchema.ps1
- File grouping is a new feature (defaults to `single` mode = same behavior as v1.x)

---

## [1.4.1] - 2026-01-20

### Fixed

**excludeObjectTypes Configuration Fully Implemented**
- The `excludeObjectTypes` configuration setting now works uniformly across all 30+ object types

**Export Progress Output Consistency**
- Default progress output now shows stage headers with milestone-only progress lines
- Per-object success lines are only shown when `-Verbose` is explicitly passed

## [1.4.0] - 2026-01-13

### Fixed

**GO Batch Separator Handling**
- Improved regex pattern for splitting SQL scripts on GO statements
- Now correctly handles:
  - `GO` with trailing spaces (e.g., `GO  `)
  - `GO` with inline comments (e.g., `GO -- comment`)
- Limitation: `GO` with repeat counts (e.g., `GO 5`) is currently treated as a single batch separator; repeat execution is not yet supported
- Note: Regex assumes SMO-generated scripts (GO not inside strings/block comments)

### Added

**FileGroup Handling in Developer Mode**
- **`autoRemap` Strategy** (new default): Automatically imports FileGroups with auto-detected paths
  - Detects SQL Server's default data directory using `SERVERPROPERTY('InstanceDefaultDataPath')`
  - Generates unique .ndf file paths automatically (no configuration required)
  - Preserves FileGroup structure for accurate development/testing
  - Works cross-platform (Windows/Linux SQL Server)
- **`removeToPrimary` Strategy** (optional): Skips FileGroups and remaps all references to PRIMARY
  - Simplifies local setup when FileGroup structure isn't needed
  - Uses regex transformations to rewrite table/index/partition scheme DDL
- New `fileGroupStrategy` configuration option in `developerMode` settings (`autoRemap` or `removeToPrimary`)
- New `Get-DefaultDataPath` function in Import-SqlServerSchema.ps1
- Enhanced test database with partitioned tables to validate partition scheme handling

### Changed
- **Breaking**: Developer Mode now imports FileGroups by default (using `autoRemap`)
  - Previous behavior (skip FileGroups) available via `fileGroupStrategy: removeToPrimary`
- Updated test validation to verify FileGroup placement
- Updated README.md with FileGroup strategy documentation
- Updated export-import-config.example.yml with `fileGroupStrategy` examples

---

## [1.3.0] - 2026-01-12

### Changed

**Performance Optimizations**
- **Export Script**: 65% faster exports (61.2s → 21.1s for 314 files in testing)
  - Reuses single SMO connection across all object types (eliminates per-category connection overhead)
  - SMO prefetch with SetDefaultInitFields eliminates N+1 lazy-loading queries
  - Consolidated output messages reduce console I/O (use `-Verbose` for detailed output)
  - Optional `-CollectMetrics` parameter for performance analysis
- **Import Script**: 91% faster imports (37.8s → 3.3s for 263 scripts in testing)
  - Single persistent connection for all script execution (eliminates N+1 connection problem)
  - Replaced slow SMO metadata enumeration with direct SQL queries in schema detection
  - Shared connection used across all preliminary validation checks

### Added
- `-CollectMetrics` parameter on both Export and Import scripts for performance diagnostics
- Performance baseline documentation in `tests/PERFORMANCE_BASELINE.md` and `tests/IMPORT_PERFORMANCE_BASELINE.md`

---

## [1.2.2] - 2025-11-19

### Fixed
- **SMO "Folder path specified does not exist" errors**: corrected handling of relative paths that were causing errors

## [1.2.1] - 2025-11-19

### Fixed
- **SMO "Folder path specified does not exist" errors**: Added directory existence check before all file operations to prevent scripting failures

## [1.2.0] - 2025-11-19

### Added

**Reliability & Error Handling**
- **Retry Logic for Transient Failures**: Automatic retry with exponential backoff for network timeouts, Azure SQL throttling, deadlocks
  - Detects 7 categories of transient errors (network timeouts, Azure SQL error codes 40501/40613/49918/etc., deadlocks, connection pool issues, transport errors)
  - Exponential backoff strategy (2s → 4s → 8s for default 3 retries)
  - Configurable via `maxRetries` (1-10) and `retryDelaySeconds` (1-60) in YAML config
  - Command-line parameter overrides: `-MaxRetries` and `-RetryDelaySeconds`
  - Verbose logging of retry attempts with error types
- **Connection Timeout Management**: Configurable connection timeouts for slow networks or Azure SQL
  - `connectionTimeout` parameter (1-300 seconds, default 30)
  - `commandTimeout` parameter (1-3600 seconds, default 300)
  - Three-tier precedence: command-line parameter > config file > hardcoded default
- **Error Logging Infrastructure**: Comprehensive error logging to file for diagnostics
  - `Write-Log` function with timestamps and severity levels (INFO, WARNING, ERROR)
  - Error log file created in output directory with timestamp
  - All errors logged with full details including script names and line numbers
  - Dual output: console for immediate feedback + file for post-mortem analysis
- **Connection Cleanup**: Finally blocks ensure connections always close, even on errors
  - Implemented in 8+ connection functions across both scripts
  - Prevents connection leaks and SQL Server resource exhaustion
  - IsOpen checks before disconnect to avoid errors

**Export Status Messages**
- Updated export status format to show percentage progress: "Exported X object(s) (Y%)" for all 35+ object types
- Improved readability with consistent [SUCCESS] prefix format

### Changed
- Configuration system expanded: Added 4 new settings (connectionTimeout, commandTimeout, maxRetries, retryDelaySeconds)
- JSON schema updated with validation rules for all new configuration parameters
- Main SQL Server connections wrapped with retry logic in both Export and Import scripts
- All script execution (Invoke-SqlScript) wrapped with retry logic for transient failure resilience

### Fixed
- Connection timeout errors on slow networks or during Azure SQL throttling
- Connection leaks when errors occur during database operations
- Transient failures causing complete script abortion (now retries automatically)
- Missing diagnostic information when errors occur (now logged to file with full context)

### Known Issues
- **excludeObjectTypes Partially Implemented**: The `excludeObjectTypes` configuration setting is only enforced for 10 of 30 object types (FileGroups, DatabaseScopedConfigurations, DatabaseScopedCredentials, Schemas, Sequences, Tables, ForeignKeys, Indexes, Functions, Views). The remaining 20 object types will still be exported even if excluded in configuration. Full implementation tracked in [Issue #12](https://github.com/ormico/Export-SqlServerSchema/issues/12).

---

## [1.1.0] - 2025-11-10

### Added

**Export Features**
- FileGroups export with SQLCMD variables (`$(FG_*_PATH_FILE)`) for cross-platform deployment
- Database Scoped Configurations (MAXDOP, optimizer settings)
- Security Policies (Row-Level Security with filter/block predicates)
- Search Property Lists (custom full-text properties)
- Plan Guides (query hint guides)
- Expanded folder structure from 12 to 21 numbered folders (00-20)

**Import Features**
- **Two-Mode System**: Developer Mode (default, schema-only) and Production Mode (full infrastructure)
- **YAML Configuration**: Simplified and full formats with JSON Schema validation
- **Cross-Platform FileGroups**: Auto-detects target OS (Windows/Linux), database-specific file naming
- **Enhanced Reporting**: Startup configuration display and comprehensive completion summaries
- **Mode-Specific Behaviors**:
  - Dev: Skips FileGroups, DB configs, external sources; disables Security Policies
  - Prod: Imports all infrastructure; enables Security Policies

**Testing & Documentation**
- Docker-based integration tests with dual-mode validation (Dev + Prod)
- Comprehensive test coverage: FileGroups, MAXDOP, Security Policies, data integrity
- Updated documentation: `EXPORT_IMPORT_STRATEGY.md`, `README.md`, `.github/copilot-instructions.md`

### Changed
- Folder numbering: 12 folders → 21 folders for new object types
- Data folder relocated: `12_Data/` → `21_Data/`
- Import default: Now defaults to Developer Mode (was Production Mode equivalent)
- FileGroup handling: Now exports with SQLCMD parameterization (was skipped)

### Fixed
- Import-YamlConfig: Removed empty nested structure addition for simplified configs
- Mode settings logic: Support both simplified and full config formats with three-tier fallback
- ALTER DATABASE CURRENT: Replaced with actual database name for compatibility
- Logical file names: Prefixed with database name to prevent multi-database conflicts
- System role filter: Exclude system roles (public, db_owner) from export
- Type constraints: Fixed to use correct SMO collection
- USE statements: Import now skips `USE [database]` from exported scripts
- Empty credentials: Fixed authentication handling for empty credential objects

### Breaking Changes
- **Folder structure incompatibility**: Re-export databases from v1.0 to use v1.1.0 features
- **Import default changed**: Add `-ImportMode Prod` for production deployments

### Migration from v1.0

```powershell
# 1. Re-export your database
./Export-SqlServerSchema.ps1 -Server localhost -Database MyDb

# 2. Update import commands for production
./Import-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -SourcePath ./exports/MyDb -ImportMode Prod

# 3. Optional: Create YAML config for repeatable deployments
# See tests/test-prod-config.yml for example
```

---

## [1.0.0] - 2024-11-09

Initial release:
- Export database schema to SQL files in dependency order
- Import with automatic FK constraint management
- Individual files per programmability object
- Data export as INSERT statements
- SQL Server 2012-2022 and Azure SQL support
- Cross-platform PowerShell 7.0+
- 12 numbered folders for object organization

[1.2.0]: https://github.com/ormico/Export-SqlServerSchema/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ormico/Export-SqlServerSchema/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ormico/Export-SqlServerSchema/releases/tag/v1.0.0
