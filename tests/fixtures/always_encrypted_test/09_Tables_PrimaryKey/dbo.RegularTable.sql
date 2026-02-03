CREATE TABLE [dbo].[RegularTable](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[Name] [nvarchar](100) NOT NULL,
	[Description] [nvarchar](max) NULL,
	CONSTRAINT [PK_RegularTable] PRIMARY KEY CLUSTERED ([Id] ASC)
) ON [PRIMARY];
GO
