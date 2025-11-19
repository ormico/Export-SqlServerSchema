# Changelog

All notable changes to Export-SqlServerSchema will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
