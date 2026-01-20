SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
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
