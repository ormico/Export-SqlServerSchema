-- Simplified Performance Test Database
-- Creates 500 tables with 100 rows each (50,000 rows), plus related objects
-- Focuses on reasonable scale for testing export/import performance
--

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE PerfTestDb;
GO

-- Create database roles FIRST (before schemas)
DECLARE @roleNum INT = 1;
WHILE @roleNum <= 5
BEGIN
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''' + @roleName + ''' AND type = ''R'')
        CREATE ROLE ' + QUOTENAME(@roleName) + ';';
    
    EXEC sp_executesql @sql;
    SET @roleNum = @roleNum + 1;
END
PRINT 'Created 5 database roles';
GO

-- Create database users SECOND (before schemas)
DECLARE @userNum INT = 1;
WHILE @userNum <= 10
BEGIN
    DECLARE @userName NVARCHAR(50) = 'TestUser' + CAST(@userNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''' + @userName + ''' AND type = ''S'')
        CREATE USER ' + QUOTENAME(@userName) + ' WITHOUT LOGIN;';
    
    EXEC sp_executesql @sql;
    SET @userNum = @userNum + 1;
END
PRINT 'Created 10 database users';
GO

-- Add users to roles
DECLARE @userNum INT = 1;
WHILE @userNum <= 10
BEGIN
    DECLARE @userName NVARCHAR(50) = 'TestUser' + CAST(@userNum AS NVARCHAR(10));
    DECLARE @roleNum INT = ((@userNum - 1) % 5) + 1;
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = 'ALTER ROLE ' + QUOTENAME(@roleName) + ' ADD MEMBER ' + QUOTENAME(@userName) + ';';
    EXEC sp_executesql @sql;
    
    SET @userNum = @userNum + 1;
END
PRINT 'Added users to roles';
GO

-- Create 10 schemas first (before granting permissions)
DECLARE @i INT = 1;
WHILE @i <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@i AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX) = 'CREATE SCHEMA ' + QUOTENAME(@schemaName);
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = @schemaName)
        EXEC sp_executesql @sql;
    SET @i = @i + 1;
END
PRINT 'Created 10 schemas';
GO

-- Grant permissions on schemas to roles (AFTER schemas are created)
DECLARE @schemaNum INT = 1;
WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @roleNum INT = ((@schemaNum - 1) % 5) + 1;
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = 'GRANT SELECT ON SCHEMA::' + QUOTENAME(@schemaName) + ' TO ' + QUOTENAME(@roleName) + ';';
    EXEC sp_executesql @sql;
    
    SET @sql = 'GRANT EXECUTE ON SCHEMA::' + QUOTENAME(@schemaName) + ' TO ' + QUOTENAME(@roleName) + ';';
    EXEC sp_executesql @sql;
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Granted permissions on schemas to roles';
GO

-- Create 500 tables (50 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @tableCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @tableNum INT = 1;
    
    WHILE @tableNum <= 50
    BEGIN
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@tableNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        CREATE TABLE ' + @tableName + ' (
            Id INT IDENTITY(1,1) PRIMARY KEY,
            Code NVARCHAR(50) NOT NULL UNIQUE,
            Name NVARCHAR(200) NOT NULL,
            Description NVARCHAR(MAX),
            Amount DECIMAL(18,2),
            Quantity INT,
            IsActive BIT DEFAULT 1,
            CreatedDate DATETIME2 DEFAULT SYSDATETIME(),
            ModifiedDate DATETIME2,
            Category NVARCHAR(50),
            Status NVARCHAR(20) DEFAULT ''Active'',
            Notes NVARCHAR(500)
        );
        
        CREATE NONCLUSTERED INDEX IX_Status ON ' + @tableName + ' (Status) INCLUDE (Name, Amount);
        CREATE NONCLUSTERED INDEX IX_Active ON ' + @tableName + ' (CreatedDate) WHERE IsActive = 1;
        ';
        
        EXEC sp_executesql @sql;
        
        SET @tableCount = @tableCount + 1;
        IF @tableCount % 100 = 0
            PRINT 'Created ' + CAST(@tableCount AS NVARCHAR(10)) + ' tables...';
        
        SET @tableNum = @tableNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 500 tables with indexes';
GO

-- Insert test data (simplified - 100 rows per table instead of 1000)
DECLARE @schemaNum INT = 1;
DECLARE @tablesPopulated INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @tableNum INT = 1;
    
    WHILE @tableNum <= 50
    BEGIN
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@tableNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Generate 100 sample rows using a tally table approach
        SET @sql = '
        INSERT INTO ' + @tableName + ' (Code, Name, Description, Amount, Quantity, Category, Status, Notes)
        SELECT TOP 100
            ''' + @schemaName + '-T' + CAST(@tableNum AS NVARCHAR(10)) + '-'' + RIGHT(''000'' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS NVARCHAR(10)), 4),
            ''Item '' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS NVARCHAR(10)),
            ''Description for item'',
            CAST((ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) * 10.50) AS DECIMAL(18,2)),
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 100,
            CASE ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 5 WHEN 0 THEN ''A'' WHEN 1 THEN ''B'' WHEN 2 THEN ''C'' WHEN 3 THEN ''D'' ELSE ''E'' END,
            CASE ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 3 WHEN 0 THEN ''Active'' WHEN 1 THEN ''Pending'' ELSE ''Inactive'' END,
            ''Notes for item''
        FROM (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t1
        CROSS JOIN (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2
        CROSS JOIN (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) t3;
        ';
        
        EXEC sp_executesql @sql;
        
        SET @tablesPopulated = @tablesPopulated + 1;
        IF @tablesPopulated % 100 = 0
            PRINT 'Populated ' + CAST(@tablesPopulated AS NVARCHAR(10)) + ' tables...';
        
        SET @tableNum = @tableNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Populated 500 tables with data (50,000 total rows)';
GO

-- Create 500 stored procedures
DECLARE @schemaNum INT = 1;
DECLARE @procCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @procNum INT = 1;
    
    WHILE @procNum <= 50
    BEGIN
        DECLARE @procName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('usp_Proc' + CAST(@procNum AS NVARCHAR(10)));
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@procNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        CREATE OR ALTER PROCEDURE ' + @procName + '
            @Status NVARCHAR(20) = NULL
        AS
        BEGIN
            SET NOCOUNT ON;
            SELECT TOP 100 Id, Code, Name, Amount, Status FROM ' + @tableName + '
            WHERE @Status IS NULL OR Status = @Status
            ORDER BY Id;
        END
        ';
        
        EXEC sp_executesql @sql;
        
        SET @procCount = @procCount + 1;
        IF @procCount % 100 = 0
            PRINT 'Created ' + CAST(@procCount AS NVARCHAR(10)) + ' stored procedures...';
        
        SET @procNum = @procNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 500 stored procedures';
GO

-- Create 100 views
DECLARE @schemaNum INT = 1;
DECLARE @viewCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @viewNum INT = 1;
    
    WHILE @viewNum <= 10
    BEGIN
        DECLARE @viewName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('vw_View' + CAST(@viewNum AS NVARCHAR(10)));
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@viewNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        CREATE OR ALTER VIEW ' + @viewName + '
        AS
        SELECT Category, Status, COUNT(*) as ItemCount, SUM(Amount) as TotalAmount
        FROM ' + @tableName + '
        GROUP BY Category, Status
        ';
        
        EXEC sp_executesql @sql;
        
        SET @viewCount = @viewCount + 1;
        SET @viewNum = @viewNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 100 views';
GO

-- Create 100 functions
DECLARE @schemaNum INT = 1;
DECLARE @funcCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @funcNum INT = 1;
    
    WHILE @funcNum <= 10
    BEGIN
        DECLARE @funcName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('fn_Func' + CAST(@funcNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        CREATE OR ALTER FUNCTION ' + @funcName + '(@Value DECIMAL(18,2))
        RETURNS DECIMAL(18,2)
        AS
        BEGIN
            RETURN @Value * 1.1;
        END
        ';
        
        EXEC sp_executesql @sql;
        
        SET @funcCount = @funcCount + 1;
        SET @funcNum = @funcNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 100 scalar functions';
GO

-- Create user-defined types (20 types - 2 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @typeCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    -- Create first type (NVARCHAR)
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.types t JOIN sys.schemas s ON t.schema_id = s.schema_id 
                  WHERE s.name = ''' + @schemaName + ''' AND t.name = ''CodeType'')
    BEGIN
        CREATE TYPE ' + QUOTENAME(@schemaName) + '.CodeType FROM NVARCHAR(50) NOT NULL;
    END';
    EXEC sp_executesql @sql;
    
    -- Create second type (DECIMAL)
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.types t JOIN sys.schemas s ON t.schema_id = s.schema_id 
                  WHERE s.name = ''' + @schemaName + ''' AND t.name = ''AmountType'')
    BEGIN
        CREATE TYPE ' + QUOTENAME(@schemaName) + '.AmountType FROM DECIMAL(18,2) NULL;
    END';
    EXEC sp_executesql @sql;
    
    SET @typeCount = @typeCount + 2;
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 20 user-defined types';
GO

-- Create 100 triggers (10 per schema, 2 per table for first 5 tables)
DECLARE @schemaNum INT = 1;
DECLARE @triggerCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @tableNum INT = 1;
    
    WHILE @tableNum <= 5
    BEGIN
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@tableNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create UPDATE trigger
        DECLARE @triggerName1 NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('trg_Update_Table' + CAST(@tableNum AS NVARCHAR(10)));
        SET @sql = '
        CREATE OR ALTER TRIGGER ' + @triggerName1 + '
        ON ' + @tableName + '
        AFTER UPDATE
        AS
        BEGIN
            SET NOCOUNT ON;
            UPDATE t
            SET ModifiedDate = SYSDATETIME()
            FROM ' + @tableName + ' t
            INNER JOIN inserted i ON t.Id = i.Id;
        END';
        EXEC sp_executesql @sql;
        SET @triggerCount = @triggerCount + 1;
        
        -- Create INSERT trigger
        DECLARE @triggerName2 NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('trg_Insert_Table' + CAST(@tableNum AS NVARCHAR(10)));
        SET @sql = '
        CREATE OR ALTER TRIGGER ' + @triggerName2 + '
        ON ' + @tableName + '
        AFTER INSERT
        AS
        BEGIN
            SET NOCOUNT ON;
            IF EXISTS (SELECT 1 FROM inserted WHERE Amount < 0)
            BEGIN
                THROW 50001, ''Amount cannot be negative'', 1;
            END
        END';
        EXEC sp_executesql @sql;
        SET @triggerCount = @triggerCount + 1;
        
        SET @tableNum = @tableNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 100 triggers';
GO

-- Create 50 synonyms (5 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @synonymCount INT = 0;

WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @synNum INT = 1;
    
    WHILE @synNum <= 5
    BEGIN
        DECLARE @synonymName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('syn_Table' + CAST(@synNum AS NVARCHAR(10)));
        DECLARE @tableName NVARCHAR(100) = QUOTENAME(@schemaName) + '.' + QUOTENAME('Table' + CAST(@synNum AS NVARCHAR(10)));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        IF EXISTS (SELECT 1 FROM sys.synonyms s JOIN sys.schemas sch ON s.schema_id = sch.schema_id 
                  WHERE sch.name = ''' + @schemaName + ''' AND s.name = ''syn_Table' + CAST(@synNum AS NVARCHAR(10)) + ''')
            DROP SYNONYM ' + @synonymName + ';
        
        CREATE SYNONYM ' + @synonymName + ' FOR ' + @tableName + ';';
        
        EXEC sp_executesql @sql;
        SET @synonymCount = @synonymCount + 1;
        
        SET @synNum = @synNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 50 synonyms';
GO

-- Summary
SELECT 'Schemas' AS ObjectType, COUNT(*) AS Count FROM sys.schemas WHERE name LIKE 'Schema%'
UNION ALL
SELECT 'Tables', COUNT(*) FROM sys.tables WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'Indexes', COUNT(*) FROM sys.indexes WHERE object_id IN (SELECT object_id FROM sys.tables WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')) AND type > 0
UNION ALL
SELECT 'Stored Procedures', COUNT(*) FROM sys.procedures WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'Views', COUNT(*) FROM sys.views WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'Functions', COUNT(*) FROM sys.objects WHERE type IN ('FN') AND schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'Triggers', COUNT(*) FROM sys.triggers WHERE parent_id IN (SELECT object_id FROM sys.tables WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%'))
UNION ALL
SELECT 'Synonyms', COUNT(*) FROM sys.synonyms WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'User-Defined Types', COUNT(*) FROM sys.types WHERE is_user_defined = 1 AND schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')
UNION ALL
SELECT 'Database Roles', COUNT(*) FROM sys.database_principals WHERE name LIKE 'AppRole%' AND type = 'R'
UNION ALL
SELECT 'Database Users', COUNT(*) FROM sys.database_principals WHERE name LIKE 'TestUser%' AND type = 'S'
UNION ALL
SELECT 'Total Data Rows', SUM(p.rows) FROM sys.partitions p WHERE object_id IN (SELECT object_id FROM sys.tables WHERE schema_id IN (SELECT schema_id FROM sys.schemas WHERE name LIKE 'Schema%')) AND p.index_id < 2;
GO

PRINT '';
PRINT '========================================';
PRINT 'Performance Test Database Created';
PRINT '========================================';
PRINT 'Objects created:';
PRINT '  - 10 schemas';
PRINT '  - 500 tables with 100 rows each';
PRINT '  - 2,000 indexes';
PRINT '  - 500 stored procedures';
PRINT '  - 100 views';
PRINT '  - 100 scalar functions';
PRINT '  - 100 triggers';
PRINT '  - 50 synonyms';
PRINT '  - 20 user-defined types';
PRINT '  - 5 database roles';
PRINT '  - 10 database users';
PRINT '  - 50,000 total data rows';
PRINT '========================================';
