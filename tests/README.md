# Test SQL Server Docker Setup

This directory contains Docker configuration and test files for validating the Export-SqlServerSchema and Import-SqlServerSchema scripts.

## Quick Start

1. Start SQL Server:
   ```bash
   docker-compose up -d
   ```

2. Wait for health check to pass (should see "healthy" status):
   ```bash
   docker-compose ps
   ```

3. Run all unit tests (no SQL Server needed):
   ```powershell
   pwsh ./run-all-unit-tests.ps1
   ```

4. Run all integration tests (requires SQL Server container):
   ```powershell
   pwsh ./run-all-integration-tests.ps1
   ```

5. Run the comprehensive integration test alone:
   ```powershell
   pwsh ./run-integration-test.ps1
   ```

## Test Autodiscovery

Tests are classified via a `# TestType:` comment header placed after the closing `#>` of the comment-based help block in each `test-*.ps1` file:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS ...
#>
# TestType: unit

param()
```

### Runners

| Runner | Discovers | SQL Server |
|--------|-----------|------------|
| `run-all-unit-tests.ps1` | `test-*.ps1` with `# TestType: unit` | Not needed |
| `run-all-integration-tests.ps1` | `test-*.ps1` with `# TestType: integration` + `run-integration-test.ps1` | Required |

- Files with a `run-` prefix are **excluded** from autodiscovery (only `test-*.ps1` is scanned).
- `run-integration-test.ps1` is explicitly appended at the end of the integration runner for fast-feedback ordering.
- Files missing a `# TestType:` header emit a warning but do not fail the run.
- `run-perf-test.ps1` is a benchmark script and is not part of autodiscovery or CI.

### Adding a New Test

1. Create `tests/test-my-feature.ps1` with the `# TestType: unit` or `# TestType: integration` header.
2. That's it — the autodiscovery runners and CI will pick it up automatically.

### Test Classification

**Unit tests** (no SQL Server needed):
- test-common-functions.ps1
- test-config-auto-discovery.ps1
- test-convert-import-report.ps1
- test-database-trust-from-env.ps1
- test-exclude-objects-import.ps1
- test-import-folder-ordering.ps1
- test-import-integrity-report.ps1
- test-index-before-fk.ps1
- test-partition-scheme-filegroup.ps1
- test-schema-bound-folder-matching.ps1
- test-use-latest-export.ps1
- test-utf8-bom-encoding.ps1
- test-validate-only.ps1

**Integration tests** (require SQL Server container):
- test-advanced-filegroups.ps1
- test-clr-strict-security.ps1
- test-connection-string-from-env.ps1
- test-encryption-fallback-scan.ps1
- test-encryption-secrets.ps1
- test-env-credentials.ps1
- test-error-handling.ps1
- test-exclude-feature.ps1
- test-export-strip-filestream.ps1
- test-minimal-config.ps1
- test-minimal-filegroups.ps1
- test-parallel-export.ps1
- test-schema-exclude-import.ps1
- test-selective-object-types.ps1
- test-strip-always-encrypted.ps1
- test-strip-filestream.ps1
- test-user-type-filtering.ps1

## Manual Testing

If you want to test individual components:

1. Create test database with schema:
   ```powershell
   pwsh ./setup-test-db.ps1
   ```

2. Export the test database:
   ```powershell
   pwsh ../Export-SqlServerSchema.ps1 -Server "localhost,1433" -Database "TestDb" -IncludeData
   ```

3. Import to a new database:
   ```powershell
   pwsh ../Import-SqlServerSchema.ps1 -Server "localhost,1433" -Database "TestDb_Restored" -SourcePath "./exports/localhost_TestDb_TIMESTAMP" -IncludeData -CreateDatabase
   ```

## Connection Details

- **Server**: localhost
- **Port**: 1433
- **Username**: sa
- **Password**: Test@1234 (configurable in .env file)
- **Test Database**: TestDb
- **Target Database**: TestDb_Restored

## Legacy Runner

- **run-unit-tests.ps1** — Original unit test runner for `ConvertFrom-AdoConnectionString` and `Resolve-EnvCredential`. Kept for direct developer use; not part of autodiscovery.

## Test Database Coverage

The test database (`test-schema.sql`) includes examples of all major SQL Server object types:

### Infrastructure Objects
- **FileGroups**: 3 filegroups (PRIMARY, FG_CURRENT, FG_ARCHIVE)
- **Database Scoped Configurations**: MAXDOP, cardinality estimator, parameter sniffing, query optimizer hotfixes
- **Database Scoped Credentials**: 2 credentials (with test secrets for export/import testing)

### Schema Objects
- **Schemas**: 3 (dbo, Sales, Warehouse)
- **Tables**: 5 with various constraints, defaults, and foreign keys
- **Views**: 1 multi-table join
- **Functions**: 3 (2 scalar functions + 1 table-valued function for RLS)
- **Stored Procedures**: 2 with parameters and error handling
- **Triggers**: 2 (AFTER UPDATE and AFTER INSERT)
- **Sequences**: 1 with custom range
- **User-Defined Types**: 1 table type
- **Indexes**: 4 non-clustered indexes

### Advanced Features
- **Security Policies**: 1 Row-Level Security policy (disabled for testing, can be enabled)
- **Synonyms**: 2 object aliases
- **Search Property Lists**: 1 list with 2 custom properties for full-text search
- **Plan Guides**: 1 query hint example

### Sample Data
- 5 customers, 6 products, 3 orders, 6 order details, 6 inventory records

### Objects NOT Included
The following objects require external resources or complex setup unsuitable for Docker-based integration tests:
- External Data Sources (requires Azure/external resources)
- External File Formats (depends on External Data Sources)
- External Libraries (requires ML Services configuration)
- External Languages (requires custom language runtime)
- Always Encrypted objects (requires certificate store configuration)
- Certificates with private keys (complex key management)

This comprehensive coverage ensures the export/import scripts handle all common database object types correctly.

## Known Issues

### SMO PrefetchObjects Synonym Limitation

During export, you may see a VERBOSE message:
```
VERBOSE: Could not prefetch Synonym: Exception calling "PrefetchObjects" with "1" argument(s): "Prefetch objects failed for Database 'TestDb'. "
```

**This is a non-fatal warning** caused by an SMO bug/limitation:
- `Database.PrefetchObjects(typeof(Synonym))` fails in SMO
- The parameterless `PrefetchObjects()` succeeds for all types including Synonyms
- Our code catches this error gracefully and falls back to lazy loading

**Impact**: None — synonyms still export correctly. The prefetch optimization simply doesn't apply to this object type.

## Stopping

```bash
docker-compose down
```

## Cleanup (removes volume)

```bash
docker-compose down -v
```
