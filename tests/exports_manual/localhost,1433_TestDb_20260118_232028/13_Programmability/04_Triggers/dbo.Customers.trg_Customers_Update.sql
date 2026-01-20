SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

-- Create a trigger on Customers table
CREATE TRIGGER [dbo].[trg_Customers_Update]
ON [dbo].[Customers]
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
ALTER TABLE [dbo].[Customers] ENABLE TRIGGER [trg_Customers_Update]
GO
