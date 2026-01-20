SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
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
