# Changelog

All notable changes to Export-SqlServerSchema will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


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
- Integration tests verify all three grouping modes work correctly
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

## [1.5.0] - 2026-01-21

Re-ordered Security roles for dependency ordering.

Expanded performance test database.

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
