-- Table: dbo.Attachments
-- Second table with FILESTREAM column
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Attachments](
    [AttachmentId] [uniqueidentifier] ROWGUIDCOL NOT NULL,
    [DocumentId] [uniqueidentifier] NOT NULL,
    [AttachmentName] [nvarchar](255) NOT NULL,
    [FileContent] [varbinary](max) FILESTREAM NULL,
    [MimeType] [nvarchar](100) NULL,
    CONSTRAINT [PK_Attachments] PRIMARY KEY CLUSTERED ([AttachmentId] ASC)
) ON [FG_DATA] FILESTREAM_ON [FG_FILESTREAM];
GO
