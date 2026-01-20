SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

-- Create a trigger on Orders table
CREATE TRIGGER [Sales].[trg_Orders_UpdateTotal]
ON [Sales].[Orders]
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
ALTER TABLE [Sales].[Orders] ENABLE TRIGGER [trg_Orders_UpdateTotal]
GO
