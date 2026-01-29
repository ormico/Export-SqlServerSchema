-- Stored Procedure: dbo.usp_GetDocumentPath
-- Returns the FILESTREAM path for a document
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[usp_GetDocumentPath]
    @DocumentId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT 
        DocumentId,
        FileName,
        Content.PathName() AS FilePath
    FROM dbo.Documents
    WHERE DocumentId = @DocumentId;
END
GO
