CREATE TABLE [dbo].[ClrTestTable](
    [Id] [int] IDENTITY(1,1) NOT NULL,
    [Name] [nvarchar](100) NULL,
    CONSTRAINT [PK_ClrTestTable] PRIMARY KEY CLUSTERED ([Id] ASC)
) ON [PRIMARY]
GO
