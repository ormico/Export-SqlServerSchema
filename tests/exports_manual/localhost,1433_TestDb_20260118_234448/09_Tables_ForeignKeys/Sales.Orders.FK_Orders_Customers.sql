ALTER TABLE [Sales].[Orders]  WITH CHECK ADD  CONSTRAINT [FK_Orders_Customers] FOREIGN KEY([CustomerId])
REFERENCES [dbo].[Customers] ([CustomerId])
GO
ALTER TABLE [Sales].[Orders] CHECK CONSTRAINT [FK_Orders_Customers]
GO
