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

3. Run the comprehensive integration test:
   ```powershell
   pwsh ./run-integration-test.ps1
   ```

   This test will:
   - Create a test database with schema
   - Export the database schema and data
   - Import to a new database
   - Verify all objects and data match
   - Test foreign key constraint management

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

## Test Files

- **run-integration-test.ps1** - Comprehensive end-to-end test (8 steps)
- **setup-test-db.ps1** - Creates test database with sample schema
- **test-schema.sql** - Test database schema definition with comprehensive object coverage
- **.env** - Configuration file (copy from .env.example)

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

**Impact**: None - synonyms still export correctly. The prefetch optimization simply doesn't apply to this object type.

**To verify**: Run `test-synonym-prefetch.ps1` which demonstrates:
- 5 of 6 object types prefetch successfully (Table, View, StoredProcedure, UserDefinedFunction, Schema)
- Only Synonym fails the typed prefetch
- Direct synonym scripting works fine

## Stopping

```bash
docker-compose down
```

## Cleanup (removes volume)

```bash
docker-compose down -v
```
