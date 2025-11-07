#Requires -Version 7.0

<#
.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    Creates a test database schema for validating DB2SCRIPT and Apply-Schema scripts.

.DESCRIPTION
    Sets up a test SQL Server database with various object types including:
    - Multiple schemas
    - Tables with PK/FK relationships
    - Stored procedures and functions
    - Views, triggers, and indexes
    - User-defined types

.PARAMETER Server
    SQL Server instance name or connection string. Default: localhost

.PARAMETER Username
    SQL Server username. Default: sa

.PARAMETER Password
    SQL Server password. Default: Test@1234

.PARAMETER Database
    Database name to create. Default: TestDb

.EXAMPLE
    ./setup-test-db.ps1
    ./setup-test-db.ps1 -Server "myserver\SQLEXPRESS" -Database "MyTestDb"
#>

param(
    [string]$Server = 'localhost',
    [string]$Username = 'sa',
    [string]$Password = 'Test@1234',
    [string]$Database = 'TestDb'
)

$ErrorActionPreference = 'Stop'

# Connection string
$connectionString = "Server=$Server;User Id=$Username;Password=$Password;"

Write-Output "Connecting to SQL Server at $Server..."

try {
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $connection.Open()
    Write-Output "✓ Connected successfully"
    $connection.Close()
} catch {
    Write-Error "✗ Failed to connect: $_"
    exit 1
}

# SQL script to create test database and schema
$setupSQL = @"
-- Drop existing database if it exists
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
BEGIN
    ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
    DROP DATABASE [$Database]
END

-- Create database
CREATE DATABASE [$Database]
GO

USE [$Database]
GO

-- Create schemas
CREATE SCHEMA Sales
GO

CREATE SCHEMA Warehouse
GO

-- Create user-defined types
CREATE TYPE dbo.ContactInfo AS TABLE (
    EmailAddress NVARCHAR(255),
    PhoneNumber NVARCHAR(20)
)
GO

-- Create tables
CREATE TABLE dbo.Customers (
    CustomerId INT PRIMARY KEY IDENTITY(1,1),
    CustomerName NVARCHAR(100) NOT NULL,
    Email NVARCHAR(100),
    CreatedDate DATETIME DEFAULT GETDATE()
)
GO

CREATE TABLE dbo.Products (
    ProductId INT PRIMARY KEY IDENTITY(1,1),
    ProductName NVARCHAR(100) NOT NULL,
    Price DECIMAL(10,2),
    StockQuantity INT DEFAULT 0
)
GO

CREATE TABLE Sales.Orders (
    OrderId INT PRIMARY KEY IDENTITY(1,1),
    CustomerId INT NOT NULL,
    OrderDate DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerId) REFERENCES dbo.Customers(CustomerId)
)
GO

CREATE TABLE Sales.OrderDetails (
    OrderDetailId INT PRIMARY KEY IDENTITY(1,1),
    OrderId INT NOT NULL,
    ProductId INT NOT NULL,
    Quantity INT DEFAULT 1,
    UnitPrice DECIMAL(10,2),
    CONSTRAINT FK_OrderDetails_Orders FOREIGN KEY (OrderId) REFERENCES Sales.Orders(OrderId),
    CONSTRAINT FK_OrderDetails_Products FOREIGN KEY (ProductId) REFERENCES dbo.Products(ProductId)
)
GO

CREATE TABLE Warehouse.InventoryMovements (
    MovementId INT PRIMARY KEY IDENTITY(1,1),
    ProductId INT NOT NULL,
    MovementType NVARCHAR(20),
    Quantity INT,
    MovementDate DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Inventory_Products FOREIGN KEY (ProductId) REFERENCES dbo.Products(ProductId)
)
GO

-- Create indexes
CREATE NONCLUSTERED INDEX IX_Customers_Email ON dbo.Customers(Email)
GO

CREATE NONCLUSTERED INDEX IX_Orders_CustomerId ON Sales.Orders(CustomerId)
GO

CREATE NONCLUSTERED INDEX IX_OrderDetails_OrderId ON Sales.OrderDetails(OrderId)
GO

-- Create user-defined function (scalar)
CREATE FUNCTION dbo.GetCustomerOrderCount(@CustomerId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT COUNT(*) FROM Sales.Orders WHERE CustomerId = @CustomerId)
END
GO

-- Create user-defined function (table-valued)
CREATE FUNCTION dbo.GetCustomerOrders(@CustomerId INT)
RETURNS TABLE
AS
RETURN (
    SELECT OrderId, OrderDate FROM Sales.Orders WHERE CustomerId = @CustomerId
)
GO

-- Create stored procedure
CREATE PROCEDURE dbo.sp_GetCustomerDetails
    @CustomerId INT
AS
BEGIN
    SELECT 
        c.CustomerId,
        c.CustomerName,
        c.Email,
        OrderCount = (SELECT COUNT(*) FROM Sales.Orders WHERE CustomerId = c.CustomerId)
    FROM dbo.Customers c
    WHERE c.CustomerId = @CustomerId
END
GO

-- Create another stored procedure
CREATE PROCEDURE Sales.sp_CreateOrder
    @CustomerId INT,
    @OrderId INT OUTPUT
AS
BEGIN
    INSERT INTO Sales.Orders (CustomerId, OrderDate)
    VALUES (@CustomerId, GETDATE())
    
    SET @OrderId = SCOPE_IDENTITY()
END
GO

-- Create view
CREATE VIEW dbo.vw_CustomerOrderSummary
AS
SELECT 
    c.CustomerId,
    c.CustomerName,
    OrderCount = COUNT(o.OrderId),
    TotalOrderValue = ISNULL(SUM(CAST(od.Quantity * od.UnitPrice AS DECIMAL(10,2))), 0)
FROM dbo.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerId = o.CustomerId
LEFT JOIN Sales.OrderDetails od ON o.OrderId = od.OrderId
GROUP BY c.CustomerId, c.CustomerName
GO

-- Create trigger
CREATE TRIGGER dbo.trg_UpdateProductStock
ON Sales.OrderDetails
AFTER INSERT
AS
BEGIN
    UPDATE dbo.Products
    SET StockQuantity = StockQuantity - inserted.Quantity
    FROM dbo.Products p
    INNER JOIN inserted ON p.ProductId = inserted.ProductId
END
GO

-- Create database trigger
CREATE TRIGGER dbo.trg_PreventDrops
ON DATABASE
FOR DROP_TABLE, DROP_PROCEDURE
AS
BEGIN
    PRINT 'Table or procedure drop denied'
    ROLLBACK
END
GO

-- Insert sample data
INSERT INTO dbo.Customers (CustomerName, Email) VALUES 
    ('John Smith', 'john@example.com'),
    ('Jane Doe', 'jane@example.com'),
    ('Bob Johnson', 'bob@example.com')
GO

INSERT INTO dbo.Products (ProductName, Price, StockQuantity) VALUES
    ('Widget A', 19.99, 100),
    ('Widget B', 29.99, 50),
    ('Gadget X', 49.99, 25)
GO

INSERT INTO Sales.Orders (CustomerId, OrderDate) VALUES
    (1, GETDATE()),
    (2, DATEADD(day, -1, GETDATE())),
    (1, DATEADD(day, -7, GETDATE()))
GO

INSERT INTO Sales.OrderDetails (OrderId, ProductId, Quantity, UnitPrice) VALUES
    (1, 1, 2, 19.99),
    (1, 3, 1, 49.99),
    (2, 2, 3, 29.99),
    (3, 1, 5, 19.99)
GO

PRINT 'Test database schema created successfully'
"@

# Execute setup script
Write-Output "Creating test database schema..."

try {
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $connection.Open()
    
    # Split on GO to handle batch execution
    $batches = $setupSQL -split '(?:^|\n)GO(?:$|\n)' | Where-Object { $_.Trim() }
    
    $batchCount = 0
    foreach ($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }
        
        $command = $connection.CreateCommand()
        $command.CommandText = $batch
        $command.CommandTimeout = 30
        
        try {
            $command.ExecuteNonQuery() | Out-Null
            $batchCount++
        } catch {
            Write-Warning "Issue executing batch $batchCount : $_"
        }
    }
    
    $connection.Close()
    Write-Output "✓ Database schema created successfully with $batchCount batches executed"
    Write-Output "✓ Test database is ready at $Server\$Database"
    
} catch {
    Write-Error "✗ Failed to create database schema: $_"
    exit 1
}
