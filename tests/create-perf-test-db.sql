-- Performance Test Database - Enhanced Version
-- Creates 5000 tables with 1000 rows each (5 million rows), plus related objects
-- Designed to stress-test the export script with realistic large database
-- 100x increase from original: 100 schemas, 5000 tables, 5000 procs, 2000 views, 3000 functions
-- Includes triggers, synonyms, user-defined types, security objects

USE PerfTestDb;
GO

-- Create 100 schemas (100x increase from 10)
DECLARE @i INT = 1;
WHILE @i <= 100
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
    DECLARE @totalTables INT = 0;
    
    -- Create 5000 tables (50 per schema, 100 schemas)
    SET @schemaNum = 1;
    WHILE @schemaNum <= 100
    BEGIN
        SET @schemaName = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
        SET @tableNum = 1;
        
        WHILE @tableNum <= 50
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
                    Notes NVARCHAR(500),
                    Priority INT DEFAULT 1,
                    AssignedTo NVARCHAR(100),
                    CompletionDate DATE,
                    Rating DECIMAL(3,2)
                );
                
                -- Add unique index on Code
                CREATE UNIQUE NONCLUSTERED INDEX IX_' + @schemaName + '_Table' + CAST(@tableNum AS NVARCHAR(10)) + '_Code 
                ON ' + @tableName + ' (Code);
                
                -- Add index on Status
                CREATE NONCLUSTERED INDEX IX_' + @schemaName + '_Table' + CAST(@tableNum AS NVARCHAR(10)) + '_Status 
                ON ' + @tableName + ' (Status) INCLUDE (Name, Amount);
                
                -- Add filtered index
                CREATE NONCLUSTERED INDEX IX_' + @schemaName + '_Table' + CAST(@tableNum AS NVARCHAR(10)) + '_Active
                ON ' + @tableName + ' (CreatedDate, Category) WHERE IsActive = 1;
            END';
            
            EXEC sp_executesql @sql;
            
            SET @totalTables = @totalTables + 1;
            IF @totalTables % 500 = 0
                PRINT 'Created ' + CAST(@totalTables AS NVARCHAR(10)) + ' tables...';
            
            SET @tableNum = @tableNum + 1;
        END
        
        SET @schemaNum = @schemaNum + 1;
    END
    
    PRINT 'Created 5000 tables with indexes';
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
    DECLARE @totalTables INT = 0;
    
    SET @schemaNum = 1;
    WHILE @schemaNum <= 100
    BEGIN
        SET @schemaName = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
        SET @tableNum = 1;
        
        WHILE @tableNum <= 50
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
                INSERT INTO ' + @tableName + ' (Code, Name, Description, Amount, Quantity, Category, Status, Notes, Priority, AssignedTo, CompletionDate, Rating)
                SELECT 
                    ''' + @schemaName + '-T' + CAST(@tableNum AS NVARCHAR(10)) + '-'' + RIGHT(''000000'' + CAST(n AS NVARCHAR(10)), 6),
                    ''Item '' + CAST(n AS NVARCHAR(10)) + '' in ' + @tableName + ''',
                    ''Description for item '' + CAST(n AS NVARCHAR(10)) + ''. This is sample data for performance testing of the export script with additional complexity.'',
                    CAST(n * 10.50 AS DECIMAL(18,2)),
                    n % 100,
                    CASE n % 5 WHEN 0 THEN ''Category A'' WHEN 1 THEN ''Category B'' WHEN 2 THEN ''Category C'' WHEN 3 THEN ''Category D'' ELSE ''Category E'' END,
                    CASE n % 3 WHEN 0 THEN ''Active'' WHEN 1 THEN ''Pending'' ELSE ''Inactive'' END,
                    ''Notes for item '' + CAST(n AS NVARCHAR(10)),
                    (n % 5) + 1,
                    CASE n % 10 WHEN 0 THEN ''User1'' WHEN 1 THEN ''User2'' WHEN 2 THEN ''User3'' WHEN 3 THEN ''User4'' WHEN 4 THEN ''User5'' 
                                  WHEN 5 THEN ''User6'' WHEN 6 THEN ''User7'' WHEN 7 THEN ''User8'' WHEN 8 THEN ''User9'' ELSE ''User10'' END,
                    DATEADD(DAY, n % 365, GETDATE()),
                    CAST((n % 50) / 10.0 AS DECIMAL(3,2))
                FROM Numbers;
            END';
            
            EXEC sp_executesql @sql;
            
            SET @totalTables = @totalTables + 1;
            IF @totalTables % 500 = 0
                PRINT 'Populated ' + CAST(@totalTables AS NVARCHAR(10)) + ' tables...';
            
            SET @tableNum = @tableNum + 1;
        END
        
        SET @schemaNum = @schemaNum + 1;
    END
    
    PRINT 'Populated 5000 tables with data';
END
GO

-- Populate with 1000 rows per table (5,000,000 total rows)
EXEC dbo.PopulatePerfTestData @RowsPerTable = 1000;
GO

-- Create user-defined types (2 per schema, 200 total)
DECLARE @schemaNum INT = 1;
DECLARE @totalTypes INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @typeNum INT = 1;
    
    WHILE @typeNum <= 2
    BEGIN
        DECLARE @typeName NVARCHAR(100) = @schemaName + '.CustomType' + CAST(@typeNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        IF @typeNum = 1
        BEGIN
            SET @sql = '
            IF NOT EXISTS (SELECT 1 FROM sys.types t JOIN sys.schemas s ON t.schema_id = s.schema_id 
                          WHERE s.name = ''' + @schemaName + ''' AND t.name = ''CustomType1'')
            BEGIN
                CREATE TYPE ' + @typeName + ' FROM NVARCHAR(100) NOT NULL;
            END';
        END
        ELSE
        BEGIN
            SET @sql = '
            IF NOT EXISTS (SELECT 1 FROM sys.types t JOIN sys.schemas s ON t.schema_id = s.schema_id 
                          WHERE s.name = ''' + @schemaName + ''' AND t.name = ''CustomType2'')
            BEGIN
                CREATE TYPE ' + @typeName + ' FROM DECIMAL(18,4) NULL;
            END';
        END
        
        EXEC sp_executesql @sql;
        SET @totalTypes = @totalTypes + 1;
        SET @typeNum = @typeNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 200 user-defined types';
GO

-- Create 5000 stored procedures (50 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalProcs INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @procNum INT = 1;
    
    WHILE @procNum <= 50
    BEGIN
        DECLARE @procName NVARCHAR(100) = @schemaName + '.usp_GetData' + CAST(@procNum AS NVARCHAR(10));
        -- Map procedure to table using modulo to cycle through 50 tables per schema
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST((((@procNum - 1) % 50) + 1) AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create different types of procedures for variety
        IF @procNum % 5 = 1
        BEGIN
            -- Basic select procedure
            SET @sql = '
            CREATE OR ALTER PROCEDURE ' + @procName + '
                @Status NVARCHAR(20) = NULL,
                @Category NVARCHAR(50) = NULL
            AS
            BEGIN
                SET NOCOUNT ON;
                SELECT Id, Code, Name, Amount, Quantity, Status, Category, Priority
                FROM ' + @tableName + '
                WHERE (@Status IS NULL OR Status = @Status)
                  AND (@Category IS NULL OR Category = @Category)
                ORDER BY Id;
            END';
        END
        ELSE IF @procNum % 5 = 2
        BEGIN
            -- Aggregate procedure
            SET @sql = '
            CREATE OR ALTER PROCEDURE ' + @procName + '
                @MinAmount DECIMAL(18,2) = 0
            AS
            BEGIN
                SET NOCOUNT ON;
                SELECT 
                    Category,
                    Status,
                    COUNT(*) AS RecordCount,
                    SUM(Amount) AS TotalAmount,
                    AVG(Amount) AS AvgAmount,
                    MAX(Amount) AS MaxAmount,
                    MIN(Amount) AS MinAmount
                FROM ' + @tableName + '
                WHERE Amount >= @MinAmount
                GROUP BY Category, Status
                HAVING COUNT(*) > 10
                ORDER BY TotalAmount DESC;
            END';
        END
        ELSE IF @procNum % 5 = 3
        BEGIN
            -- Update procedure
            SET @sql = '
            CREATE OR ALTER PROCEDURE ' + @procName + '
                @Id INT,
                @NewStatus NVARCHAR(20)
            AS
            BEGIN
                SET NOCOUNT ON;
                UPDATE ' + @tableName + '
                SET Status = @NewStatus,
                    ModifiedDate = SYSDATETIME()
                WHERE Id = @Id;
                
                SELECT @@ROWCOUNT AS RowsAffected;
            END';
        END
        ELSE IF @procNum % 5 = 4
        BEGIN
            -- Insert procedure
            SET @sql = '
            CREATE OR ALTER PROCEDURE ' + @procName + '
                @Code NVARCHAR(50),
                @Name NVARCHAR(200),
                @Amount DECIMAL(18,2),
                @Category NVARCHAR(50)
            AS
            BEGIN
                SET NOCOUNT ON;
                INSERT INTO ' + @tableName + ' (Code, Name, Amount, Category)
                VALUES (@Code, @Name, @Amount, @Category);
                
                SELECT SCOPE_IDENTITY() AS NewId;
            END';
        END
        ELSE
        BEGIN
            -- Complex query procedure
            SET @sql = '
            CREATE OR ALTER PROCEDURE ' + @procName + '
                @TopN INT = 100
            AS
            BEGIN
                SET NOCOUNT ON;
                WITH RankedData AS (
                    SELECT 
                        *,
                        ROW_NUMBER() OVER (PARTITION BY Category ORDER BY Amount DESC) AS RowNum,
                        DENSE_RANK() OVER (ORDER BY CreatedDate DESC) AS DateRank
                    FROM ' + @tableName + '
                    WHERE IsActive = 1
                )
                SELECT TOP (@TopN)
                    Id, Code, Name, Category, Amount, Status, RowNum, DateRank
                FROM RankedData
                WHERE RowNum <= 10
                ORDER BY DateRank, RowNum;
            END';
        END
        
        EXEC sp_executesql @sql;
        SET @totalProcs = @totalProcs + 1;
        
        IF @totalProcs % 500 = 0
            PRINT 'Created ' + CAST(@totalProcs AS NVARCHAR(10)) + ' stored procedures...';
        
        SET @procNum = @procNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 5000 stored procedures';
GO

-- Create 2000 views (20 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalViews INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @viewNum INT = 1;
    
    WHILE @viewNum <= 20
    BEGIN
        DECLARE @viewName NVARCHAR(100) = @schemaName + '.vw_Summary' + CAST(@viewNum AS NVARCHAR(10));
        -- Map view to table using modulo to cycle through 50 tables per schema
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST((((@viewNum - 1) % 50) + 1) AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create different types of views for variety
        IF @viewNum % 4 = 1
        BEGIN
            -- Simple aggregation view
            SET @sql = '
            CREATE OR ALTER VIEW ' + @viewName + '
            AS
            SELECT 
                Category,
                Status,
                COUNT(*) AS ItemCount,
                SUM(Amount) AS TotalAmount,
                AVG(Quantity) AS AvgQuantity,
                MAX(Amount) AS MaxAmount,
                MIN(CreatedDate) AS FirstCreated
            FROM ' + @tableName + '
            GROUP BY Category, Status';
        END
        ELSE IF @viewNum % 4 = 2
        BEGIN
            -- Filtered view
            SET @sql = '
            CREATE OR ALTER VIEW ' + @viewName + '
            AS
            SELECT 
                Id, Code, Name, Amount, Quantity, Category, Status, Priority
            FROM ' + @tableName + '
            WHERE IsActive = 1 AND Status = ''Active''';
        END
        ELSE IF @viewNum % 4 = 3
        BEGIN
            -- Calculated columns view
            SET @sql = '
            CREATE OR ALTER VIEW ' + @viewName + '
            AS
            SELECT 
                Id,
                Code,
                Name,
                Amount,
                Quantity,
                Amount * Quantity AS TotalValue,
                CASE 
                    WHEN Amount > 10000 THEN ''High''
                    WHEN Amount > 5000 THEN ''Medium''
                    ELSE ''Low''
                END AS PriceRange,
                DATEDIFF(DAY, CreatedDate, SYSDATETIME()) AS DaysOld
            FROM ' + @tableName + '
            WHERE Amount IS NOT NULL';
        END
        ELSE
        BEGIN
            -- Top N view
            SET @sql = '
            CREATE OR ALTER VIEW ' + @viewName + '
            AS
            SELECT TOP 1000
                Id, Code, Name, Category, Amount, Status, CreatedDate
            FROM ' + @tableName + '
            WHERE IsActive = 1
            ORDER BY Amount DESC';
        END
        
        EXEC sp_executesql @sql;
        SET @totalViews = @totalViews + 1;
        
        IF @totalViews % 500 = 0
            PRINT 'Created ' + CAST(@totalViews AS NVARCHAR(10)) + ' views...';
        
        SET @viewNum = @viewNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 2000 views';
GO

-- Create 2000 scalar functions (20 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalScalarFuncs INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @funcNum INT = 1;
    
    WHILE @funcNum <= 20
    BEGIN
        DECLARE @funcName NVARCHAR(100) = @schemaName + '.fn_Calculate' + CAST(@funcNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create different types of scalar functions
        IF @funcNum % 4 = 1
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@Amount DECIMAL(18,2), @Quantity INT)
            RETURNS DECIMAL(18,2)
            AS
            BEGIN
                RETURN @Amount * @Quantity * ' + CAST(@funcNum AS NVARCHAR(10)) + '.0;
            END';
        END
        ELSE IF @funcNum % 4 = 2
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@Value1 DECIMAL(18,2), @Value2 DECIMAL(18,2))
            RETURNS DECIMAL(18,2)
            AS
            BEGIN
                DECLARE @Result DECIMAL(18,2);
                SET @Result = (@Value1 + @Value2) / 2.0;
                RETURN @Result;
            END';
        END
        ELSE IF @funcNum % 4 = 3
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@InputDate DATETIME2)
            RETURNS INT
            AS
            BEGIN
                RETURN DATEDIFF(DAY, @InputDate, SYSDATETIME());
            END';
        END
        ELSE
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@Price DECIMAL(18,2))
            RETURNS NVARCHAR(20)
            AS
            BEGIN
                RETURN CASE 
                    WHEN @Price > 10000 THEN ''Premium''
                    WHEN @Price > 5000 THEN ''Standard''
                    ELSE ''Basic''
                END;
            END';
        END
        
        EXEC sp_executesql @sql;
        SET @totalScalarFuncs = @totalScalarFuncs + 1;
        SET @funcNum = @funcNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 2000 scalar functions';
GO

-- Create 1000 table-valued functions (10 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalTVFs INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @tvfNum INT = 1;
    
    WHILE @tvfNum <= 10
    BEGIN
        DECLARE @funcName NVARCHAR(100) = @schemaName + '.fn_GetTopItems' + CAST(@tvfNum AS NVARCHAR(10));
        -- Map function to table using modulo to cycle through 50 tables per schema
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST((((@tvfNum - 1) % 50) + 1) AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create different types of table-valued functions
        IF @tvfNum % 3 = 1
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@TopN INT)
            RETURNS TABLE
            AS
            RETURN
            (
                SELECT TOP (@TopN) Id, Code, Name, Amount, Category, Status
                FROM ' + @tableName + '
                WHERE IsActive = 1
                ORDER BY Amount DESC
            )';
        END
        ELSE IF @tvfNum % 3 = 2
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@Category NVARCHAR(50), @MinAmount DECIMAL(18,2))
            RETURNS TABLE
            AS
            RETURN
            (
                SELECT Id, Code, Name, Amount, Quantity, Status
                FROM ' + @tableName + '
                WHERE Category = @Category
                  AND Amount >= @MinAmount
                  AND IsActive = 1
            )';
        END
        ELSE
        BEGIN
            SET @sql = '
            CREATE OR ALTER FUNCTION ' + @funcName + '(@Status NVARCHAR(20))
            RETURNS TABLE
            AS
            RETURN
            (
                SELECT 
                    Category,
                    COUNT(*) AS RecordCount,
                    SUM(Amount) AS TotalAmount,
                    AVG(Amount) AS AvgAmount
                FROM ' + @tableName + '
                WHERE Status = @Status
                GROUP BY Category
            )';
        END
        
        EXEC sp_executesql @sql;
        SET @totalTVFs = @totalTVFs + 1;
        
        IF @totalTVFs % 500 = 0
            PRINT 'Created ' + CAST(@totalTVFs AS NVARCHAR(10)) + ' table-valued functions...';
        
        SET @tvfNum = @tvfNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 1000 table-valued functions';
GO

-- Create 1000 triggers (10 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalTriggers INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @trigNum INT = 1;
    
    WHILE @trigNum <= 10
    BEGIN
        DECLARE @triggerName NVARCHAR(100) = @schemaName + '.trg_AuditTable' + CAST(@trigNum AS NVARCHAR(10));
        -- Map trigger to table using modulo to cycle through 50 tables per schema
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST((((@trigNum - 1) % 50) + 1) AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        -- Create different types of triggers
        IF @trigNum % 3 = 1
        BEGIN
            -- Update trigger
            SET @sql = '
            CREATE OR ALTER TRIGGER ' + @triggerName + '
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
        END
        ELSE IF @trigNum % 3 = 2
        BEGIN
            -- Insert trigger
            SET @sql = '
            CREATE OR ALTER TRIGGER ' + @triggerName + '
            ON ' + @tableName + '
            AFTER INSERT
            AS
            BEGIN
                SET NOCOUNT ON;
                -- Validate data on insert
                IF EXISTS (SELECT 1 FROM inserted WHERE Amount < 0)
                BEGIN
                    THROW 50001, ''Amount cannot be negative'', 1;
                END
            END';
        END
        ELSE
        BEGIN
            -- Delete trigger
            SET @sql = '
            CREATE OR ALTER TRIGGER ' + @triggerName + '
            ON ' + @tableName + '
            INSTEAD OF DELETE
            AS
            BEGIN
                SET NOCOUNT ON;
                -- Soft delete - mark as inactive instead of deleting
                UPDATE t
                SET IsActive = 0,
                    ModifiedDate = SYSDATETIME()
                FROM ' + @tableName + ' t
                INNER JOIN deleted d ON t.Id = d.Id;
            END';
        END
        
        EXEC sp_executesql @sql;
        SET @totalTriggers = @totalTriggers + 1;
        
        IF @totalTriggers % 500 = 0
            PRINT 'Created ' + CAST(@totalTriggers AS NVARCHAR(10)) + ' triggers...';
        
        SET @trigNum = @trigNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 1000 triggers';
GO

-- Create 500 synonyms (5 per schema)
DECLARE @schemaNum INT = 1;
DECLARE @totalSynonyms INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @synNum INT = 1;
    
    WHILE @synNum <= 5
    BEGIN
        DECLARE @synonymName NVARCHAR(100) = @schemaName + '.syn_Table' + CAST(@synNum AS NVARCHAR(10));
        DECLARE @tableName NVARCHAR(100) = @schemaName + '.Table' + CAST(@synNum AS NVARCHAR(10));
        DECLARE @sql NVARCHAR(MAX);
        
        SET @sql = '
        IF EXISTS (SELECT 1 FROM sys.synonyms s JOIN sys.schemas sch ON s.schema_id = sch.schema_id 
                  WHERE sch.name = ''' + @schemaName + ''' AND s.name = ''syn_Table' + CAST(@synNum AS NVARCHAR(10)) + ''')
            DROP SYNONYM ' + @synonymName + ';
        
        CREATE SYNONYM ' + @synonymName + ' FOR ' + @tableName + ';';
        
        EXEC sp_executesql @sql;
        SET @totalSynonyms = @totalSynonyms + 1;
        
        SET @synNum = @synNum + 1;
    END
    
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Created 500 synonyms';
GO

-- Create database roles
DECLARE @roleNum INT = 1;
WHILE @roleNum <= 10
BEGIN
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''' + @roleName + ''' AND type = ''R'')
        CREATE ROLE ' + QUOTENAME(@roleName) + ';';
    
    EXEC sp_executesql @sql;
    SET @roleNum = @roleNum + 1;
END
PRINT 'Created 10 database roles';
GO

-- Create database users
DECLARE @userNum INT = 1;
WHILE @userNum <= 20
BEGIN
    DECLARE @userName NVARCHAR(50) = 'TestUser' + CAST(@userNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = '
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''' + @userName + ''' AND type = ''S'')
        CREATE USER ' + QUOTENAME(@userName) + ' WITHOUT LOGIN;';
    
    EXEC sp_executesql @sql;
    SET @userNum = @userNum + 1;
END
PRINT 'Created 20 database users';
GO

-- Grant permissions on objects to roles and users
DECLARE @schemaNum INT = 1;
DECLARE @permissionsGranted INT = 0;
WHILE @schemaNum <= 100
BEGIN
    DECLARE @schemaName NVARCHAR(50) = 'Schema' + CAST(@schemaNum AS NVARCHAR(10));
    DECLARE @roleNum INT = ((@schemaNum - 1) % 10) + 1;
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    -- Grant SELECT on schema to role
    SET @sql = 'GRANT SELECT ON SCHEMA::' + QUOTENAME(@schemaName) + ' TO ' + QUOTENAME(@roleName) + ';';
    EXEC sp_executesql @sql;
    
    -- Grant EXECUTE on schema to role
    SET @sql = 'GRANT EXECUTE ON SCHEMA::' + QUOTENAME(@schemaName) + ' TO ' + QUOTENAME(@roleName) + ';';
    EXEC sp_executesql @sql;
    
    SET @permissionsGranted = @permissionsGranted + 2;
    SET @schemaNum = @schemaNum + 1;
END
PRINT 'Granted permissions on 100 schemas to roles';
GO

-- Add users to roles
DECLARE @userNum INT = 1;
WHILE @userNum <= 20
BEGIN
    DECLARE @userName NVARCHAR(50) = 'TestUser' + CAST(@userNum AS NVARCHAR(10));
    DECLARE @roleNum INT = ((@userNum - 1) % 10) + 1;
    DECLARE @roleName NVARCHAR(50) = 'AppRole' + CAST(@roleNum AS NVARCHAR(10));
    DECLARE @sql NVARCHAR(MAX);
    
    SET @sql = 'ALTER ROLE ' + QUOTENAME(@roleName) + ' ADD MEMBER ' + QUOTENAME(@userName) + ';';
    EXEC sp_executesql @sql;
    
    SET @userNum = @userNum + 1;
END
PRINT 'Added 20 users to roles';
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
SELECT 'Scalar Functions', COUNT(*) FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND o.type IN ('FN')
UNION ALL
SELECT 'Table-Valued Functions', COUNT(*) FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND o.type IN ('IF', 'TF')
UNION ALL
SELECT 'Triggers', COUNT(*) FROM sys.triggers t JOIN sys.tables tb ON t.parent_id = tb.object_id JOIN sys.schemas s ON tb.schema_id = s.schema_id WHERE s.name LIKE 'Schema%'
UNION ALL
SELECT 'Synonyms', COUNT(*) FROM sys.synonyms sy JOIN sys.schemas s ON sy.schema_id = s.schema_id WHERE s.name LIKE 'Schema%'
UNION ALL
SELECT 'User-Defined Types', COUNT(*) FROM sys.types ty JOIN sys.schemas s ON ty.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND ty.is_user_defined = 1
UNION ALL
SELECT 'Database Roles', COUNT(*) FROM sys.database_principals WHERE name LIKE 'AppRole%' AND type = 'R'
UNION ALL
SELECT 'Database Users', COUNT(*) FROM sys.database_principals WHERE name LIKE 'TestUser%' AND type = 'S'
UNION ALL
SELECT 'Total Rows', SUM(p.rows) FROM sys.partitions p JOIN sys.tables t ON p.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name LIKE 'Schema%' AND p.index_id < 2;
GO

PRINT '========================================';
PRINT 'Enhanced Performance Test Database Created';
PRINT '========================================';
PRINT 'Objects created (100x increase from original):';
PRINT '  - 100 schemas (was 10)';
PRINT '  - 5000 tables with 1000 rows each (was 50)';
PRINT '  - 15000 indexes - 3 per table (was 100)';
PRINT '  - 5000 stored procedures (was 50)';
PRINT '  - 2000 views (was 20)';
PRINT '  - 2000 scalar functions (was 20)';
PRINT '  - 1000 table-valued functions (was 10)';
PRINT '  - 1000 triggers (NEW)';
PRINT '  - 500 synonyms (NEW)';
PRINT '  - 200 user-defined types (NEW)';
PRINT '  - 10 database roles (NEW)';
PRINT '  - 20 database users (NEW)';
PRINT '  - 5,000,000 total data rows (was 50,000)';
PRINT '========================================';
GO
