# Changelog

All notable changes to Export-SqlServerSchema will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/ormico/Export-SqlServerSchema/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ormico/Export-SqlServerSchema/releases/tag/v1.0.0
