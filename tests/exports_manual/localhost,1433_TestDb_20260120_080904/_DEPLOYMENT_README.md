# Database Schema Export: TestDb

Export Date: 2026-01-20 08:09:34
Source Server: localhost,1433
Source Database: TestDb

## Deployment Order

Scripts must be applied in the following order to ensure all dependencies are satisfied:

0. 00_FileGroups - Create filegroups (review paths for target environment)
1. 01_DatabaseConfiguration - Apply database scoped configurations (review hardware-specific settings)
2. 02_Schemas - Create database schemas
3. 03_Sequences - Create sequences
4. 04_PartitionFunctions - Create partition functions
5. 05_PartitionSchemes - Create partition schemes
6. 06_Types - Create user-defined types
7. 07_XmlSchemaCollections - Create XML schema collections
8. 08_Tables_PrimaryKey - Create tables with primary keys (no foreign keys)
9. 09_Tables_ForeignKeys - Add foreign key constraints
10. 10_Indexes - Create indexes
11. 11_Defaults - Create default constraints
12. 12_Rules - Create rules
13. 13_Programmability - Create assemblies, functions, procedures, triggers, views (in subfolder order)
14. 14_Synonyms - Create synonyms
15. 15_FullTextSearch - Create full-text search objects
16. 16_ExternalData - Create external data sources and file formats (review connection strings)
17. 17_SearchPropertyLists - Create search property lists
18. 18_PlanGuides - Create plan guides
19. 19_Security - Create security objects (keys, certificates, roles, users, audit, Row-Level Security)
20. 20_Data - Load data

## Important Notes

- FileGroups (00): Environment-specific file paths - review and adjust for target server's storage configuration
- Database Configuration (01): Hardware-specific settings like MAXDOP - review for target server capabilities
- External Data (16): Connection strings and URLs are environment-specific - configure for target environment
- Database Scoped Credentials: Always excluded from export (secrets cannot be scripted safely)

## Using Import-SqlServerSchema.ps1

To apply this schema to a target database:

```powershell
# Basic usage (Windows authentication) - Dev mode
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904"

# With SQL authentication
$cred = Get-Credential
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -Credential $cred

# Production mode (includes FileGroups, DB Configurations, External Data)
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -ImportMode Prod

# Include data
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -IncludeData

# Create database if it doesn't exist
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -CreateDatabase

# Force apply even if schema already exists
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -Force

# Continue on errors (useful for idempotency)
./Import-SqlServerSchema.ps1 -Server "target-server" -Database "target-db" -SourcePath "localhost,1433_TestDb_20260120_080904" -ContinueOnError
```

## Notes

- Scripts are in dependency order for initial deployment
- Foreign keys are separated from table creation to ensure all referenced tables exist first
- Triggers and views are deployed after all underlying objects
- Data scripts are optional and can be skipped if desired
- Use -Force flag to redeploy schema even if objects already exist
- Use -ImportMode Dev (default) for development, -ImportMode Prod for production deployments

