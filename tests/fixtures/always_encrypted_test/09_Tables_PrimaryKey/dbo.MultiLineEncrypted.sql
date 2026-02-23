CREATE TABLE [dbo].[MultiLineEncrypted](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[TaxId] [varchar](20) COLLATE Latin1_General_BIN2
		ENCRYPTED WITH (
			COLUMN_ENCRYPTION_KEY = [CEK_SSN],
			ENCRYPTION_TYPE = Deterministic,
			ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
		) NOT NULL,
	[Notes] [nvarchar](500) NULL,
	CONSTRAINT [PK_MultiLineEncrypted] PRIMARY KEY CLUSTERED ([Id] ASC)
) ON [PRIMARY];
GO
