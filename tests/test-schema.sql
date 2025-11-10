-- Test Database Schema for SQL Server Scripting Toolkit
-- This creates a realistic test database with various object types

-- Create database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TestDb')
BEGIN
    ALTER DATABASE [TestDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [TestDb];
END
GO

CREATE DATABASE [TestDb];
GO

USE [TestDb];
GO

-- ═══════════════════════════════════════════════════════════════
-- FILEGROUPS (SQL Server 2022 supports multiple filegroups)
-- ═══════════════════════════════════════════════════════════════
-- Note: FileGroups are created at database level but we're adding them post-creation
-- In production, these would be created with CREATE DATABASE

-- Add SECONDARY filegroup for current/active data
ALTER DATABASE [TestDb] ADD FILEGROUP [FG_CURRENT];
GO

ALTER DATABASE [TestDb] ADD FILE (
    NAME = N'TestDb_Current',
    FILENAME = N'/var/opt/mssql/data/TestDb_Current.ndf',
    SIZE = 8MB,
    FILEGROWTH = 64MB
) TO FILEGROUP [FG_CURRENT];
GO

-- Add ARCHIVE filegroup for historical data
ALTER DATABASE [TestDb] ADD FILEGROUP [FG_ARCHIVE];
GO

ALTER DATABASE [TestDb] ADD FILE (
    NAME = N'TestDb_Archive',
    FILENAME = N'/var/opt/mssql/data/TestDb_Archive.ndf',
    SIZE = 8MB,
    FILEGROWTH = 64MB
) TO FILEGROUP [FG_ARCHIVE];
GO

-- ═══════════════════════════════════════════════════════════════
-- DATABASE SCOPED CONFIGURATIONS (SQL Server 2016+)
-- ═══════════════════════════════════════════════════════════════
-- These settings override server-level defaults for this database

-- Set MAXDOP to 4 (production might be 8, but test environment has fewer cores)
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4;
GO

-- Use modern cardinality estimator (SQL Server 2014+)
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = OFF;
GO

-- Enable parameter sniffing optimization
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SNIFFING = ON;
GO

-- Enable query optimizer hotfixes
ALTER DATABASE SCOPED CONFIGURATION SET QUERY_OPTIMIZER_HOTFIXES = ON;
GO

-- ═══════════════════════════════════════════════════════════════
-- CREATE SCHEMAS
-- ═══════════════════════════════════════════════════════════════

-- Create additional schemas
CREATE SCHEMA Sales;
GO

CREATE SCHEMA Warehouse;
GO

-- ═══════════════════════════════════════════════════════════════
-- SEQUENCES
-- ═══════════════════════════════════════════════════════════════

CREATE SEQUENCE [dbo].[test-SEQ] 
 AS [bigint]
 START WITH -9223372036854775808
 INCREMENT BY 1
 MINVALUE -9223372036854775808
 MAXVALUE 9223372036854775807
 CACHE 
GO

-- ═══════════════════════════════════════════════════════════════
-- USER-DEFINED TYPES
-- ═══════════════════════════════════════════════════════════════

-- Create user-defined table type
CREATE TYPE dbo.ContactInfo AS TABLE (
    EmailAddress NVARCHAR(255),
    PhoneNumber NVARCHAR(20)
);
GO

-- Create tables with relationships
CREATE TABLE dbo.Customers (
    CustomerId INT PRIMARY KEY IDENTITY(1,1),
    CustomerName NVARCHAR(100) NOT NULL,
    Email NVARCHAR(100),
    PhoneNumber NVARCHAR(20),
    CreatedDate DATETIME DEFAULT GETDATE(),
    ModifiedDate DATETIME
);
GO

CREATE TABLE dbo.Products (
    ProductId INT PRIMARY KEY IDENTITY(1,1),
    ProductName NVARCHAR(100) NOT NULL,
    ProductCode NVARCHAR(50) UNIQUE,
    Price DECIMAL(10,2) CHECK (Price >= 0),
    StockQuantity INT DEFAULT 0,
    CategoryId INT
);
GO

CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY IDENTITY(1,1),
    CustomerId INT NOT NULL,
    OrderDate DATETIME DEFAULT GETDATE(),
    TotalAmount DECIMAL(12,2),
    Status NVARCHAR(20) DEFAULT 'Pending',
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerId) 
        REFERENCES dbo.Customers(CustomerId)
);
GO

CREATE TABLE Sales.OrderDetails (
    OrderDetailId INT PRIMARY KEY IDENTITY(1,1),
    OrderId INT NOT NULL,
    ProductId INT NOT NULL,
    Quantity INT NOT NULL CHECK (Quantity > 0),
    UnitPrice DECIMAL(10,2) NOT NULL,
    Discount DECIMAL(5,2) DEFAULT 0,
    CONSTRAINT FK_OrderDetails_Orders FOREIGN KEY (OrderId) 
        REFERENCES Sales.Orders(OrderId),
    CONSTRAINT FK_OrderDetails_Products FOREIGN KEY (ProductId) 
        REFERENCES dbo.Products(ProductId)
);
GO

CREATE TABLE Warehouse.Inventory (
    InventoryId INT PRIMARY KEY IDENTITY(1,1),
    ProductId INT NOT NULL,
    LocationCode NVARCHAR(20),
    QuantityOnHand INT DEFAULT 0,
    LastUpdated DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Inventory_Products FOREIGN KEY (ProductId) 
        REFERENCES dbo.Products(ProductId)
);
GO

-- Create indexes
CREATE NONCLUSTERED INDEX IX_Customers_Email 
    ON dbo.Customers(Email);
GO

CREATE NONCLUSTERED INDEX IX_Products_ProductCode 
    ON dbo.Products(ProductCode);
GO

CREATE NONCLUSTERED INDEX IX_Orders_CustomerId 
    ON Sales.Orders(CustomerId);
GO

CREATE NONCLUSTERED INDEX IX_Orders_OrderDate 
    ON Sales.Orders(OrderDate DESC);
GO

-- Create a view
CREATE VIEW Sales.vw_CustomerOrders
AS
SELECT 
    c.CustomerId,
    c.CustomerName,
    c.Email,
    o.OrderId,
    o.OrderDate,
    o.TotalAmount,
    o.Status
FROM dbo.Customers c
INNER JOIN Sales.Orders o ON c.CustomerId = o.CustomerId;
GO

-- Create a function
CREATE FUNCTION dbo.fn_GetCustomerOrderCount(@CustomerId INT)
RETURNS INT
AS
BEGIN
    DECLARE @OrderCount INT;
    SELECT @OrderCount = COUNT(*)
    FROM Sales.Orders
    WHERE CustomerId = @CustomerId;
    RETURN ISNULL(@OrderCount, 0);
END;
GO

-- Create another function
CREATE FUNCTION dbo.fn_CalculateOrderTotal(@OrderId INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    DECLARE @Total DECIMAL(12,2);
    SELECT @Total = SUM(Quantity * UnitPrice * (1 - Discount/100))
    FROM Sales.OrderDetails
    WHERE OrderId = @OrderId;
    RETURN ISNULL(@Total, 0);
END;
GO

-- Create a stored procedure
CREATE PROCEDURE dbo.usp_AddCustomer
    @CustomerName NVARCHAR(100),
    @Email NVARCHAR(100) = NULL,
    @PhoneNumber NVARCHAR(20) = NULL,
    @CustomerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    INSERT INTO dbo.Customers (CustomerName, Email, PhoneNumber, CreatedDate)
    VALUES (@CustomerName, @Email, @PhoneNumber, GETDATE());
    
    SET @CustomerId = SCOPE_IDENTITY();
END;
GO

-- Create another stored procedure
CREATE PROCEDURE Sales.usp_CreateOrder
    @CustomerId INT,
    @OrderId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = @CustomerId)
    BEGIN
        RAISERROR('Customer does not exist', 16, 1);
        RETURN;
    END
    
    INSERT INTO Sales.Orders (CustomerId, OrderDate, Status)
    VALUES (@CustomerId, GETDATE(), 'Pending');
    
    SET @OrderId = SCOPE_IDENTITY();
END;
GO

-- Create a trigger on Customers table
CREATE TRIGGER dbo.trg_Customers_Update
ON dbo.Customers
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    UPDATE dbo.Customers
    SET ModifiedDate = GETDATE()
    FROM dbo.Customers c
    INNER JOIN inserted i ON c.CustomerId = i.CustomerId;
END;
GO

-- Create a trigger on Orders table
CREATE TRIGGER Sales.trg_Orders_UpdateTotal
ON Sales.Orders
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    UPDATE o
    SET TotalAmount = dbo.fn_CalculateOrderTotal(o.OrderId)
    FROM Sales.Orders o
    INNER JOIN inserted i ON o.OrderId = i.OrderId;
END;
GO

-- ═══════════════════════════════════════════════════════════════
-- DATABASE SCOPED CREDENTIALS (SQL Server 2016+)
-- ═══════════════════════════════════════════════════════════════
-- NOTE: These are exported as commented-out structures (secrets removed)
-- This demonstrates what would be exported and require manual configuration

-- Example 1: Azure Blob Storage credential
-- In export, this would be commented out with instructions
CREATE DATABASE SCOPED CREDENTIAL [AzureBlobCredential]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = 'test_sas_token_placeholder_12345';
GO

-- Example 2: Generic credential for external access
CREATE DATABASE SCOPED CREDENTIAL [TestExternalCredential]
WITH IDENTITY = 'test_user',
SECRET = 'test_password_placeholder';
GO

-- ═══════════════════════════════════════════════════════════════
-- SECURITY POLICIES - ROW LEVEL SECURITY (SQL Server 2016+)
-- ═══════════════════════════════════════════════════════════════

-- Add TenantId column to Orders table for multi-tenancy demo
ALTER TABLE Sales.Orders ADD TenantId INT NOT NULL DEFAULT 1;
GO

-- Create security predicate function
CREATE FUNCTION dbo.fn_TenantAccessPredicate(@TenantId INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN 
    SELECT 1 AS fn_TenantAccessPredicate_result
    WHERE 
        @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
        OR IS_MEMBER('db_owner') = 1  -- Admins bypass RLS
        OR ORIGINAL_LOGIN() = 'sa';   -- SA bypasses RLS
GO

-- Create security policy
CREATE SECURITY POLICY Sales.TenantSecurityPolicy
ADD FILTER PREDICATE dbo.fn_TenantAccessPredicate(TenantId) ON Sales.Orders,
ADD BLOCK PREDICATE dbo.fn_TenantAccessPredicate(TenantId) ON Sales.Orders AFTER INSERT
WITH (STATE = OFF);  -- Off by default for testing, can be enabled in production
GO

-- ═══════════════════════════════════════════════════════════════
-- SYNONYMS
-- ═══════════════════════════════════════════════════════════════

-- Synonym for commonly accessed view
CREATE SYNONYM dbo.CustomerOrders FOR Sales.vw_CustomerOrders;
GO

-- Synonym for table in different schema
CREATE SYNONYM dbo.OrdersAlias FOR Sales.Orders;
GO

-- ═══════════════════════════════════════════════════════════════
-- FULL-TEXT SEARCH PROPERTY LISTS (SQL Server 2012+)
-- ═══════════════════════════════════════════════════════════════

-- Create a custom search property list for document metadata
CREATE SEARCH PROPERTY LIST DocumentPropertyList;
GO

-- Add custom properties (using well-known property set GUIDs)
-- These would be used for searching custom document properties
ALTER SEARCH PROPERTY LIST DocumentPropertyList
ADD 'Author'
WITH (
    PROPERTY_SET_GUID = 'F29F85E0-4FF9-1068-AB91-08002B27B3D9',
    PROPERTY_INT_ID = 4,
    PROPERTY_DESCRIPTION = 'Document author metadata'
);
GO

ALTER SEARCH PROPERTY LIST DocumentPropertyList
ADD 'Title'
WITH (
    PROPERTY_SET_GUID = 'F29F85E0-4FF9-1068-AB91-08002B27B3D9',
    PROPERTY_INT_ID = 2,
    PROPERTY_DESCRIPTION = 'Document title metadata'
);
GO

-- ═══════════════════════════════════════════════════════════════
-- PLAN GUIDES (SQL Server 2005+)
-- ═══════════════════════════════════════════════════════════════
-- Plan guides force specific query plans - typically environment-specific

-- Create plan guide for customer order query optimization
EXEC sp_create_plan_guide 
    @name = N'CustomerOrdersPlanGuide',
    @stmt = N'SELECT c.CustomerId, c.CustomerName, COUNT(o.OrderId) as OrderCount
FROM dbo.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerId = o.CustomerId
GROUP BY c.CustomerId, c.CustomerName',
    @type = N'SQL',
    @module_or_batch = NULL,
    @params = NULL,
    @hints = N'OPTION (HASH JOIN, MAXDOP 2)';
GO

-- ═══════════════════════════════════════════════════════════════
-- SAMPLE DATA
-- ═══════════════════════════════════════════════════════════════

-- Insert sample data
INSERT INTO dbo.Customers (CustomerName, Email, PhoneNumber, CreatedDate)
VALUES 
    ('John Doe', 'john.doe@example.com', '555-0100', GETDATE()),
    ('Jane Smith', 'jane.smith@example.com', '555-0101', GETDATE()),
    ('Bob Johnson', 'bob.johnson@example.com', '555-0102', GETDATE()),
    ('Alice Williams', 'alice.williams@example.com', '555-0103', GETDATE()),
    ('Charlie Brown', 'charlie.brown@example.com', '555-0104', GETDATE());
GO

INSERT INTO dbo.Products (ProductName, ProductCode, Price, StockQuantity, CategoryId)
VALUES 
    ('Widget A', 'WDG-001', 19.99, 100, 1),
    ('Widget B', 'WDG-002', 29.99, 75, 1),
    ('Gadget X', 'GDG-001', 49.99, 50, 2),
    ('Gadget Y', 'GDG-002', 59.99, 40, 2),
    ('Tool Alpha', 'TL-001', 89.99, 25, 3),
    ('Tool Beta', 'TL-002', 99.99, 20, 3);
GO

-- Insert orders using the stored procedure
DECLARE @OrderId1 INT, @OrderId2 INT, @OrderId3 INT;

EXEC Sales.usp_CreateOrder @CustomerId = 1, @OrderId = @OrderId1 OUTPUT;
EXEC Sales.usp_CreateOrder @CustomerId = 2, @OrderId = @OrderId2 OUTPUT;
EXEC Sales.usp_CreateOrder @CustomerId = 3, @OrderId = @OrderId3 OUTPUT;

-- Insert order details
INSERT INTO Sales.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
VALUES 
    (@OrderId1, 1, 2, 19.99, 0),
    (@OrderId1, 3, 1, 49.99, 5),
    (@OrderId2, 2, 3, 29.99, 10),
    (@OrderId2, 4, 1, 59.99, 0),
    (@OrderId3, 5, 1, 89.99, 15),
    (@OrderId3, 6, 2, 99.99, 10);
GO

-- Insert inventory
INSERT INTO Warehouse.Inventory (ProductId, LocationCode, QuantityOnHand, LastUpdated)
SELECT 
    ProductId,
    'WH-' + RIGHT('000' + CAST(ProductId AS VARCHAR(3)), 3),
    StockQuantity,
    GETDATE()
FROM dbo.Products;
GO

-- Create a database-level trigger (commented out as it may interfere with testing)
-- CREATE TRIGGER trg_DatabaseAudit
-- ON DATABASE
-- FOR CREATE_TABLE, ALTER_TABLE, DROP_TABLE
-- AS
-- BEGIN
--     SET NOCOUNT ON;
--     PRINT 'Database schema change detected';
-- END;
-- GO

PRINT '';
PRINT '═══════════════════════════════════════════════════════════════';
PRINT 'TEST DATABASE CREATED SUCCESSFULLY';
PRINT '═══════════════════════════════════════════════════════════════';
PRINT 'Database: TestDb';
PRINT '';
PRINT 'SCHEMAS (3)';
PRINT '  - dbo (default)';
PRINT '  - Sales';
PRINT '  - Warehouse';
PRINT '';
PRINT 'INFRASTRUCTURE OBJECTS';
PRINT '  - FileGroups: 3 (PRIMARY, FG_CURRENT, FG_ARCHIVE)';
PRINT '  - Database Scoped Configurations: 4 settings';
PRINT '  - Database Scoped Credentials: 2 (with test secrets)';
PRINT '';
PRINT 'SCHEMA OBJECTS';
PRINT '  - Tables: 5 (Customers, Products, Orders, OrderDetails, Inventory)';
PRINT '  - Views: 1';
PRINT '  - Functions: 3 (2 scalar + 1 table-valued for RLS)';
PRINT '  - Stored Procedures: 2';
PRINT '  - Triggers: 2';
PRINT '  - Sequences: 1';
PRINT '  - User-Defined Types: 1';
PRINT '  - Indexes: 4 non-clustered';
PRINT '';
PRINT 'ADVANCED FEATURES';
PRINT '  - Security Policies: 1 (Row-Level Security - DISABLED for testing)';
PRINT '  - Synonyms: 2';
PRINT '  - Search Property Lists: 1 (2 custom properties)';
PRINT '  - Plan Guides: 1';
PRINT '';
PRINT 'SAMPLE DATA';
PRINT '  - Customers: 5 rows';
PRINT '  - Products: 6 rows';
PRINT '  - Orders: 3 rows';
PRINT '  - OrderDetails: 6 rows';
PRINT '  - Inventory: 6 rows';
PRINT '';
PRINT 'OBJECTS NOT INCLUDED (require external resources or complex setup):';
PRINT '  - External Data Sources (requires Azure/external resources)';
PRINT '  - External File Formats (depends on External Data Sources)';
PRINT '  - External Libraries (requires ML Services)';
PRINT '  - External Languages (requires custom runtime)';
PRINT '  - Always Encrypted objects (requires certificate store)';
PRINT '  - Certificates with private keys (complex key management)';
PRINT '═══════════════════════════════════════════════════════════════';
GO
