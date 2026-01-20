ALTER TABLE [Warehouse].[Inventory]  WITH CHECK ADD  CONSTRAINT [FK_Inventory_Products] FOREIGN KEY([ProductId])
REFERENCES [dbo].[Products] ([ProductId])
GO
ALTER TABLE [Warehouse].[Inventory] CHECK CONSTRAINT [FK_Inventory_Products]
GO
