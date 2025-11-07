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
- **test-schema.sql** - Test database schema definition
- **.env** - Configuration file (copy from .env.example)

## Stopping

```bash
docker-compose down
```

## Cleanup (removes volume)

```bash
docker-compose down -v
```
