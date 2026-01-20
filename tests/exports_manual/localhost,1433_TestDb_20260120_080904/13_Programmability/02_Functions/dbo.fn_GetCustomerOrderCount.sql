SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
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
