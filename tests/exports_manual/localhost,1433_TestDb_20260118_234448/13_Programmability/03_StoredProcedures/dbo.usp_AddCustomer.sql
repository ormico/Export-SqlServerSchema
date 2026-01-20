SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
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
