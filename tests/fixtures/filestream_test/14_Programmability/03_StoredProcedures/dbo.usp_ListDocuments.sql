-- Stored Procedure: dbo.usp_ListDocuments
-- Lists all documents with metadata
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[usp_ListDocuments]
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT 
        DocumentId,
        FileName,
        CreatedDate,
        DATALENGTH(Content) AS ContentSize
    FROM dbo.Documents
    ORDER BY CreatedDate DESC;
END
GO
