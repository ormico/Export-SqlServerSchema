-- Performance Test Database
-- Creates 50 tables with 1000 rows each, plus related objects
-- Designed to stress-test the export script

USE PerfTestDb;
GO

-- Create 10 schemas
DECLARE @i INT = 1;
WHILE @i <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@i AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX) = 'CREATE SCHEMA ' + QUOTENAME(@schemaName);
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = @schemaName)
        EXEC sp_executesql @sql;
    SET @i = @i + 1;
END
GO

-- Create a procedure to generate tables with data
CREATE OR ALTER PROCEDURE dbo.GeneratePerfTestObjects
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @schemaNum INT, @tableNum INT;
    DECLARE @schemaName NVARCHAR(50), @tableName NVARCHAR(100);
    DECLARE @sql NVARCHAR(MAX);
    
    -- Create 50 tables (5 per schema)
    SET @schemaNum = 1;
    WHILE @schemaNum <= 10
    BEGIN
        SET @schemaName = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
        SET @tableNum = 1;
        
        WHILE @tableNum <= 5
        BEGIN
            SET @tableName = @schemaName + '.Table' + CAST(@tableNum AS NVARCHAR(10));
            
            -- Create table if not exists
            SET @sql = '
            IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
                          WHERE s.name = ''' + @schemaName + ''' AND t.name = ''Table' + CAST(@tableNum AS NVARCHAR(10)) + ''')
            BEGIN
                CREATE TABLE ' + @tableName + ' (
                    Id INT IDENTITY(1,1) PRIMARY KEY,
                    Code NVARCHAR(50) NOT NULL,
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
                
                -- Add unique index on Code
                CREATE UNIQUE NONCLUSTERED INDEX IX_' + @schemaName + '_Table' + CAST(@tableNum AS NVARCHAR(10)) + '_Code 
                ON ' + @tableName + ' (Code);
                
                -- Add index on Status
                CREATE NONCLUSTERED INDEX IX_' + @schemaName + '_Table' + CAST(@tableNum AS NVARCHAR(10)) + '_Status 
                ON ' + @tableName + ' (Status) INCLUDE (Name, Amount);
            END';
            
            EXEC sp_executesql @sql;
            
            SET @tableNum = @tableNum + 1;
        END
        
        SET @schemaNum = @schemaNum + 1;
    END
    
    PRINT 'Created 50 tables with indexes';
END
GO

EXEC dbo.GeneratePerfTestObjects;
GO

-- Create procedure to populate tables with data
CREATE OR ALTER PROCEDURE dbo.PopulatePerfTestData
    @RowsPerTable INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @schemaNum INT, @tableNum INT;
    DECLARE @schemaName NVARCHAR(50), @tableName NVARCHAR(100);
    DECLARE @sql NVARCHAR(MAX);
    
    SET @schemaNum = 1;
    WHILE @schemaNum <= 10
    BEGIN
        SET @schemaName = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
        SET @tableNum = 1;
        
        WHILE @tableNum <= 5
        BEGIN
            SET @tableName = @schemaName + '.Table' + CAST(@tableNum AS NVARCHAR(10));
            
            -- Check if table already has data
            SET @sql = '
            IF NOT EXISTS (SELECT TOP 1 1 FROM ' + @tableName + ')
            BEGIN
                -- Insert rows
                ;WITH Numbers AS (
                    SELECT TOP ' + CAST(@RowsPerTable AS NVARCHAR(10)) + ' 
                        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
                    FROM sys.objects a CROSS JOIN sys.objects b
                )
                INSERT INTO ' + @tableName + ' (Code, Name, Description, Amount, Quantity, Category, Status, Notes)
                SELECT 
                    ''' + @schemaName + '-T' + CAST(@tableNum AS NVARCHAR(10)) + '-'' + RIGHT(''000000'' + CAST(n AS NVARCHAR(10)), 6),
                    ''Item '' + CAST(n AS NVARCHAR(10)) + '' in ' + @tableName + ''',
                    ''Description for item '' + CAST(n AS NVARCHAR(10)) + ''. This is sample data for performance testing of the export script.'',
                    CAST(n * 10.50 AS DECIMAL(18,2)),
                    n % 100,
                    CASE n % 5 WHEN 0 THEN ''Category A'' WHEN 1 THEN ''Category B'' WHEN 2 THEN ''Category C'' WHEN 3 THEN ''Category D'' ELSE ''Category E'' END,
                    CASE n % 3 WHEN 0 THEN ''Active'' WHEN 1 THEN ''Pending'' ELSE ''Inactive'' END,
                    ''Notes for item '' + CAST(n AS NVARCHAR(10))
                FROM Numbers;
                
                PRINT ''Populated ' + @tableName + ' with ' + CAST(@RowsPerTable AS NVARCHAR(10)) + ' rows'';
            END';
            
            EXEC sp_executesql @sql;
            
            SET @tableNum = @tableNum + 1;
        END
        
        SET @schemaNum = @schemaNum + 1;
    END
END
GO

-- Populate with 1000 rows per table (50,000 total rows)
EXEC dbo.PopulatePerfTestData @RowsPerTable = 1000;
GO

-- Create 50 stored procedures (5 per schema)
DECLARE @schemaNum INT = 1;
WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @procNum INT = 1;
    
    WHILE @procNum <= 5
    BEGIN
        DECLARE @procName NVARCHAR(100) = @schemaName + '.usp_GetData' + CAST(@procNum AS NVARCHAR(10));
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST(@procNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX) = '
        CREATE OR ALTER PROCEDURE ' + @procName + '
            @Status NVARCHAR(20) = NULL,
            @Category NVARCHAR(50) = NULL
        AS
        BEGIN
            SET NOCOUNT ON;
            SELECT Id, Code, Name, Amount, Quantity, Status, Category
            FROM ' + @tableName + '
            WHERE (@Status IS NULL OR Status = @Status)
              AND (@Category IS NULL OR Category = @Category)
            ORDER BY Id;
        END';
        
        EXEC sp_executesql @sql;
        SET @procNum = @procNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
GO

-- Create 20 views (2 per schema)
DECLARE @schemaNum INT = 1;
WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @viewNum INT = 1;
    
    WHILE @viewNum <= 2
    BEGIN
        DECLARE @viewName NVARCHAR(100) = @schemaName + '.vw_Summary' + CAST(@viewNum AS NVARCHAR(10));
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST(@viewNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX) = '
        CREATE OR ALTER VIEW ' + @viewName + '
        AS
        SELECT 
            Category,
            Status,
            COUNT(*) AS ItemCount,
            SUM(Amount) AS TotalAmount,
            AVG(Quantity) AS AvgQuantity
        FROM ' + @tableName + '
        GROUP BY Category, Status';
        
        EXEC sp_executesql @sql;
        SET @viewNum = @viewNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
GO

-- Create 20 scalar functions (2 per schema)
DECLARE @schemaNum INT = 1;
WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @funcNum INT = 1;
    
    WHILE @funcNum <= 2
    BEGIN
        DECLARE @funcName NVARCHAR(100) = @schemaName + '.fn_Calculate' + CAST(@funcNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX) = '
        CREATE OR ALTER FUNCTION ' + @funcName + '(@Amount DECIMAL(18,2), @Quantity INT)
        RETURNS DECIMAL(18,2)
        AS
        BEGIN
            RETURN @Amount * @Quantity * ' + CAST(@funcNum AS NVARCHAR(10)) + '.0;
        END';
        
        EXEC sp_executesql @sql;
        SET @funcNum = @funcNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
GO

-- Create 10 table-valued functions (1 per schema)
DECLARE @schemaNum INT = 1;
WHILE @schemaNum <= 10
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @funcName NVARCHAR(100) = @schemaName + '.fn_GetTopItems';
    DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table1';
    DECLARE @sql NVARCHAR(MAX) = '
    CREATE OR ALTER FUNCTION ' + @funcName + '(@TopN INT)
    RETURNS TABLE
    AS
    RETURN
    (
        SELECT TOP (@TopN) Id, Code, Name, Amount
        FROM ' + @tableName + '
        ORDER BY Amount DESC
    )';
    
    EXEC sp_executesql @sql;
    SET @schemaNum = @schemaNum + 1;
END
GO

-- Summary
SELECT 
    'Schemas' AS ObjectType, COUNT(*) AS Count FROM sys.schemas WHERE name LIKE 'Schema%'
UNION ALL
SELECT 'Tables', COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name LIKE 'Schema%'
UNION ALL
SELECT 'Indexes', COUNT(*) FROM sys.indexes i JOIN sys.tables t ON i.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND i.type > 0
UNION ALL
SELECT 'Stored Procedures', COUNT(*) FROM sys.procedures p JOIN sys.schemas s ON p.schema_id = s.schema_id WHERE s.name LIKE 'Schema%'
UNION ALL
SELECT 'Views', COUNT(*) FROM sys.views v JOIN sys.schemas s ON v.schema_id = s.schema_id WHERE s.name LIKE 'Schema%'
UNION ALL
SELECT 'Functions', COUNT(*) FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND o.type IN ('FN', 'IF', 'TF')
UNION ALL
SELECT 'Total Rows', SUM(p.rows) FROM sys.partitions p JOIN sys.tables t ON p.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND p.index_id < 2;
GO

PRINT '========================================';
PRINT 'Performance Test Database Created';
PRINT '========================================';
PRINT 'Objects created:';
PRINT '  - 10 schemas';
PRINT '  - 50 tables with 1000 rows each';
PRINT '  - 100 indexes (2 per table)';
PRINT '  - 50 stored procedures';
PRINT '  - 20 views';
PRINT '  - 30 functions';
PRINT '  - 50,000 total data rows';
PRINT '========================================';
GO
