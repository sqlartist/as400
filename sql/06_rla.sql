/*===========================================================================
  AS/400 in SQL Server 2025  —  06: record-level access
  ---------------------------------------------------------------------------
  SETLL, SETGT, CHAIN, READ, READE, READP, READPE, WRITE, UPDATE, DELETE.

  The whole layer rests on one idea: an open file has a POSITION in the
  access path, and every operation either moves it or reads from it. So the
  state we have to keep is tiny.

      POSSTATE  'BOF'     before the first record
                'BEFORE'  positioned before record CURRRN
                'AT'      positioned on record CURRRN
                'EOF'     past the last record

  Position is a relative record number and nothing else. Everything the
  operations need beyond that — the key values to compare against — is read
  back out of the record itself, so there is no cached key tuple to go stale
  when somebody updates a key field underneath us.

  Ordering is (key fields..., RRN). The RRN tiebreak is not decoration: it is
  what makes duplicate keys work. Two records with the same key are still
  strictly ordered, so READE can walk all of them and stop cleanly.

  SQL Server has no row-value comparison, so the tuple predicate is generated:

      k1 > c.k1  OR (k1 = c.k1 AND
     (k2 > c.k2  OR (k2 = c.k2 AND
      RRN > c.RRN)))

  Indicators after every operation, on QSYS.OPEN_FILE:
      F_FOUND  %FOUND   F_EOF  %EOF   F_EQUAL  %EQUAL   F_ERROR  %ERROR
===========================================================================*/

DROP TABLE IF EXISTS QSYS.RECORD_BUF;
DROP TABLE IF EXISTS QSYS.OPEN_FILE;
GO

CREATE TABLE QSYS.OPEN_FILE
(
    OPENID   INT IDENTITY(1,1) NOT NULL,
    JOBID    INT             NULL,
    OBJID    INT             NOT NULL,
    FMTID    INT             NOT NULL,
    BASETABLE NVARCHAR(256)  NOT NULL,
    MBRNAME  VARCHAR(10)     NOT NULL,
    OPENOPT  VARCHAR(10)     NOT NULL DEFAULT '*ALL',
    POSSTATE VARCHAR(10)     NOT NULL DEFAULT 'BOF',
    CURRRN   INT             NULL,
    LASTOP   VARCHAR(10)     NOT NULL DEFAULT '*OPEN',
    F_FOUND  BIT             NOT NULL DEFAULT 0,
    F_EOF    BIT             NOT NULL DEFAULT 0,
    F_EQUAL  BIT             NOT NULL DEFAULT 0,
    F_ERROR  BIT             NOT NULL DEFAULT 0,
    CONSTRAINT PK_OPEN_FILE PRIMARY KEY CLUSTERED (OPENID),
    CONSTRAINT CK_OPEN_POSSTATE CHECK (POSSTATE IN ('BOF','BEFORE','AT','EOF'))
);
GO

/*---------------------------------------------------------------------------
  The record buffer. After a read, the record format's fields ARE the
  program's variables — which is exactly what this is, and why it drops
  straight into QSYS.RENDER without translation.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.RECORD_BUF
(
    OPENID  INT             NOT NULL,
    FLDNAME VARCHAR(10)     NOT NULL,
    VAL     VARCHAR(256)    NULL,
    CONSTRAINT PK_RECORD_BUF PRIMARY KEY CLUSTERED (OPENID, FLDNAME),
    CONSTRAINT FK_BUF_OPEN FOREIGN KEY (OPENID)
        REFERENCES QSYS.OPEN_FILE (OPENID) ON DELETE CASCADE
);
GO

/*===========================================================================
  Internal helpers — the SQL fragments every operation is built from.
===========================================================================*/

/*---------------------------------------------------------------------------
  The access path: key columns in key sequence.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.RLA_KEYLIST (@FMTID INT, @PREFIX NVARCHAR(10))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN
    (
        SELECT STRING_AGG(CAST(@PREFIX + QUOTENAME(FLDNAME) AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY KEYSEQ)
        FROM   QSYS.FIELD WHERE FMTID = @FMTID AND ISKEY = 1
    );
END;
GO

/*---------------------------------------------------------------------------
  Unpivot the record into (FLDNAME, VAL) pairs for the buffer.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.RLA_BUFLIST (@FMTID INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN
    (
        SELECT STRING_AGG(CAST(
                   N'(''' + FLDNAME + N''', CAST(r.' + QUOTENAME(FLDNAME) +
                   N' AS VARCHAR(256)))' AS NVARCHAR(MAX)), N',' + CHAR(10) + N'            ')
               WITHIN GROUP (ORDER BY FLDSEQ)
        FROM   QSYS.FIELD WHERE FMTID = @FMTID
    );
END;
GO

/*---------------------------------------------------------------------------
  The strict tuple comparison against a reference row aliased 'c'.
  @DIR 'NEXT' walks forward, 'PRIOR' walks back.
  Built inside-out so the RRN tiebreak sits at the innermost level.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.RLA_TUPLE (@FMTID INT, @DIR NVARCHAR(10))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @OP NCHAR(1) = CASE WHEN @DIR = N'PRIOR' THEN N'<' ELSE N'>' END;
    DECLARE @SQL NVARCHAR(MAX) = N't.RRN ' + @OP + N' c.RRN';

    DECLARE @K TABLE (KEYSEQ INT, FLDNAME VARCHAR(10));
    INSERT @K SELECT KEYSEQ, FLDNAME FROM QSYS.FIELD WHERE FMTID = @FMTID AND ISKEY = 1;

    DECLARE @SEQ INT = (SELECT MAX(KEYSEQ) FROM @K), @F NVARCHAR(130);

    WHILE @SEQ >= 1
    BEGIN
        SELECT @F = QUOTENAME(FLDNAME) FROM @K WHERE KEYSEQ = @SEQ;
        SET @SQL = N'(t.' + @F + N' ' + @OP + N' c.' + @F + N'
                 OR (t.' + @F + N' = c.' + @F + N' AND ' + @SQL + N'))';
        SET @SEQ = @SEQ - 1;
    END;

    RETURN @SQL;
END;
GO

/*---------------------------------------------------------------------------
  Equality against supplied key parameters, for however many key fields the
  caller gave — a partial key is legal and common (READE over a part number
  when the file is keyed on part number plus sequence).
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.RLA_KEYEQ
    (@FMTID INT, @NKEYS INT, @ALIAS NVARCHAR(10))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN ISNULL(
    (
        SELECT STRING_AGG(CAST(
                   N' AND ' + @ALIAS + N'.' + QUOTENAME(FLDNAME) + N' = CAST(@K' +
                   CAST(KEYSEQ AS NVARCHAR(2)) + N' AS ' +
                   QSYS.DDS_SQLTYPE(DTYPE, FLDLEN, DECPOS) + N')'
                   AS NVARCHAR(MAX)), N'')
               WITHIN GROUP (ORDER BY KEYSEQ)
        FROM   QSYS.FIELD
        WHERE  FMTID = @FMTID AND ISKEY = 1 AND KEYSEQ <= @NKEYS
    ), N'');
END;
GO

/*---------------------------------------------------------------------------
  Comparison against supplied key parameters for SETLL / SETGT:
  the same tuple shape, but against literals rather than a reference row,
  and only over the key fields the caller supplied.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.RLA_KEYCMP
    (@FMTID INT, @NKEYS INT, @OP NVARCHAR(2))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @SQL NVARCHAR(MAX) = CASE WHEN @OP LIKE N'%=' THEN N'1=1' ELSE N'1=0' END;

    DECLARE @K TABLE (KEYSEQ INT, FLDNAME VARCHAR(10), CAST_TO NVARCHAR(50));
    INSERT @K
    SELECT KEYSEQ, FLDNAME, QSYS.DDS_SQLTYPE(DTYPE, FLDLEN, DECPOS)
    FROM   QSYS.FIELD WHERE FMTID = @FMTID AND ISKEY = 1 AND KEYSEQ <= @NKEYS;

    DECLARE @SEQ INT = (SELECT MAX(KEYSEQ) FROM @K), @F NVARCHAR(130), @P NVARCHAR(200);
    DECLARE @BARE NCHAR(1) = LEFT(@OP, 1);

    WHILE @SEQ >= 1
    BEGIN
        SELECT @F = QUOTENAME(FLDNAME),
               @P = N'CAST(@K' + CAST(@SEQ AS NVARCHAR(2)) + N' AS ' + CAST_TO + N')'
        FROM   @K WHERE KEYSEQ = @SEQ;

        SET @SQL = N'(t.' + @F + N' ' + @BARE + N' ' + @P + N'
                 OR (t.' + @F + N' = ' + @P + N' AND ' + @SQL + N'))';
        SET @SEQ = @SEQ - 1;
    END;

    RETURN @SQL;
END;
GO

/*===========================================================================
  OPNDBF / CLOF
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.OPNDBF
    @FILE   VARCHAR(100),
    @MBR    VARCHAR(10) = NULL,
    @OPENID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @L VARCHAR(10) = QSYS.QUAL_LIB(@FILE, '*LIBL');
    DECLARE @F VARCHAR(10) = QSYS.QUAL_OBJ(@FILE);

    DECLARE @OBJID INT, @TBL NVARCHAR(256), @FMTID INT;
    SELECT TOP (1) @OBJID = O.OBJID, @TBL = FI.BASETABLE
    FROM   QSYS.OBJECT AS O
    JOIN   QSYS.[FILE] AS FI ON FI.OBJID = O.OBJID
    WHERE  O.OBJNAME = @F AND O.OBJTYPE = '*FILE' AND FI.FILETYPE = 'PF'
      AND  (@L = '*LIBL' OR O.LIBNAME = @L);

    IF @OBJID IS NULL THROW 50060, N'CPF4101 - File not found or not a PF.', 1;

    SELECT @FMTID = FMTID FROM QSYS.RECORD_FORMAT WHERE OBJID = @OBJID;

    IF NOT EXISTS (SELECT 1 FROM QSYS.FIELD WHERE FMTID = @FMTID AND ISKEY = 1)
        THROW 50061, N'CPF4102 - File has no access path (no key fields).', 1;

    INSERT QSYS.OPEN_FILE (OBJID, FMTID, BASETABLE, MBRNAME)
    VALUES (@OBJID, @FMTID, @TBL, UPPER(ISNULL(@MBR, @F)));

    SET @OPENID = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE QSYS.CLOF @OPENID INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE QSYS.OPEN_FILE WHERE OPENID = @OPENID;   -- buffer cascades
END;
GO

/*---------------------------------------------------------------------------
  Reset the indicators before every operation, as the machine does.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.RLA_BEGIN @OPENID INT, @OP VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE QSYS.OPEN_FILE
       SET LASTOP = @OP, F_FOUND = 0, F_EOF = 0, F_EQUAL = 0, F_ERROR = 0
     WHERE OPENID = @OPENID;
    DELETE QSYS.RECORD_BUF WHERE OPENID = @OPENID;
END;
GO

/*===========================================================================
  SETLL — position before the first record whose key is >= the given key.
  SETGT — position before the first record whose key is >  the given key.

  Neither reads a record. SETLL sets %EQUAL when an exact match exists,
  which is the cheap existence test every RPG programmer reaches for.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.SETLL
    @OPENID INT,
    @K1 VARCHAR(256) = NULL, @K2 VARCHAR(256) = NULL,
    @K3 VARCHAR(256) = NULL, @K4 VARCHAR(256) = NULL,
    @GT BIT = 0                                  -- 1 makes this a SETGT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.RLA_BEGIN @OPENID, @OP = '*SETLL';

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10);
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    DECLARE @NKEYS INT =
        CASE WHEN @K4 IS NOT NULL THEN 4 WHEN @K3 IS NOT NULL THEN 3
             WHEN @K2 IS NOT NULL THEN 2 WHEN @K1 IS NOT NULL THEN 1 ELSE 0 END;

    IF @NKEYS = 0
    BEGIN
        -- SETLL *LOVAL: back to the top of the access path
        UPDATE QSYS.OPEN_FILE SET POSSTATE = 'BOF', CURRRN = NULL WHERE OPENID = @OPENID;
        RETURN;
    END;

    DECLARE @SQL NVARCHAR(MAX) =
        N'SELECT TOP (1) @RRN = t.RRN FROM ' + @TBL + N' AS t
          WHERE t.MBRNAME = @MBR AND ' +
          QSYS.RLA_KEYCMP(@FMTID, @NKEYS, CASE WHEN @GT = 1 THEN N'>' ELSE N'>=' END) + N'
          ORDER BY ' + QSYS.RLA_KEYLIST(@FMTID, N't.') + N', t.RRN;';

    DECLARE @RRN INT;
    EXEC sp_executesql @SQL,
         N'@MBR VARCHAR(10), @K1 VARCHAR(256), @K2 VARCHAR(256),
           @K3 VARCHAR(256), @K4 VARCHAR(256), @RRN INT OUTPUT',
         @MBR, @K1, @K2, @K3, @K4, @RRN OUTPUT;

    UPDATE QSYS.OPEN_FILE
       SET POSSTATE = CASE WHEN @RRN IS NULL THEN 'EOF' ELSE 'BEFORE' END,
           CURRRN   = @RRN,
           LASTOP   = CASE WHEN @GT = 1 THEN '*SETGT' ELSE '*SETLL' END
     WHERE OPENID = @OPENID;

    -- %EQUAL: does a record with exactly this key exist?
    IF @GT = 0
    BEGIN
        DECLARE @EQSQL NVARCHAR(MAX) =
            N'SELECT TOP (1) @N = 1 FROM ' + @TBL + N' AS t
              WHERE t.MBRNAME = @MBR' + QSYS.RLA_KEYEQ(@FMTID, @NKEYS, N't') + N';';
        DECLARE @N INT;
        EXEC sp_executesql @EQSQL,
             N'@MBR VARCHAR(10), @K1 VARCHAR(256), @K2 VARCHAR(256),
               @K3 VARCHAR(256), @K4 VARCHAR(256), @N INT OUTPUT',
             @MBR, @K1, @K2, @K3, @K4, @N OUTPUT;

        UPDATE QSYS.OPEN_FILE SET F_EQUAL = CASE WHEN @N = 1 THEN 1 ELSE 0 END
         WHERE OPENID = @OPENID;
    END;
END;
GO

CREATE OR ALTER PROCEDURE QSYS.SETGT
    @OPENID INT,
    @K1 VARCHAR(256) = NULL, @K2 VARCHAR(256) = NULL,
    @K3 VARCHAR(256) = NULL, @K4 VARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.SETLL @OPENID, @K1, @K2, @K3, @K4, @GT = 1;
END;
GO

/*===========================================================================
  READ / READP — next or prior record in the access path.
  READE / READPE — the same, but stop when the key stops matching.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.READ_REC
    @OPENID INT,
    @PRIOR  BIT = 0,
    @K1 VARCHAR(256) = NULL, @K2 VARCHAR(256) = NULL,
    @K3 VARCHAR(256) = NULL, @K4 VARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OP VARCHAR(10) =
        CASE WHEN @PRIOR = 1 AND @K1 IS NOT NULL THEN '*READPE'
             WHEN @PRIOR = 1 THEN '*READP'
             WHEN @K1 IS NOT NULL THEN '*READE'
             ELSE '*READ' END;

    EXEC QSYS.RLA_BEGIN @OPENID, @OP;

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10),
            @POS VARCHAR(10), @CUR INT;
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME,
           @POS = POSSTATE, @CUR = CURRRN
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    -- Already off the end in the direction of travel: nothing to do.
    IF (@PRIOR = 0 AND @POS = 'EOF') OR (@PRIOR = 1 AND @POS = 'BOF')
    BEGIN
        UPDATE QSYS.OPEN_FILE SET F_EOF = 1 WHERE OPENID = @OPENID;
        RETURN;
    END;

    DECLARE @NKEYS INT =
        CASE WHEN @K4 IS NOT NULL THEN 4 WHEN @K3 IS NOT NULL THEN 3
             WHEN @K2 IS NOT NULL THEN 2 WHEN @K1 IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @DIR NVARCHAR(10) = CASE WHEN @PRIOR = 1 THEN N'PRIOR' ELSE N'NEXT' END;
    DECLARE @ORD NVARCHAR(10) = CASE WHEN @PRIOR = 1 THEN N' DESC' ELSE N' ASC' END;

    /*  'BEFORE r' going forward means r itself is the next record, so the
        candidate set includes it. Every other case is a strict step away
        from the record we are sitting on.                                */
    DECLARE @WHERE NVARCHAR(MAX);

    IF (@POS = 'BOF' AND @PRIOR = 0) OR (@POS = 'EOF' AND @PRIOR = 1)
        SET @WHERE = N'1=1';
    ELSE IF @POS = 'BEFORE' AND @PRIOR = 0
        SET @WHERE = N'(t.RRN = c.RRN OR ' + QSYS.RLA_TUPLE(@FMTID, N'NEXT') + N')';
    ELSE
        SET @WHERE = QSYS.RLA_TUPLE(@FMTID, @DIR);

    DECLARE @FROMC NVARCHAR(MAX) =
        CASE WHEN @WHERE = N'1=1' THEN N''
             ELSE N' CROSS JOIN (SELECT * FROM ' + @TBL +
                  N' WHERE MBRNAME = @MBR AND RRN = @CUR) AS c' END;

    DECLARE @SQL NVARCHAR(MAX) =
        N'SELECT TOP (1) @RRN = r.RRN, @BUF = 1 FROM (
            SELECT TOP (1) t.* FROM ' + @TBL + N' AS t' + @FROMC + N'
            WHERE t.MBRNAME = @MBR AND ' + @WHERE +
            QSYS.RLA_KEYEQ(@FMTID, @NKEYS, N't') + N'
            ORDER BY ' +
            REPLACE(QSYS.RLA_KEYLIST(@FMTID, N't.'), N', ', @ORD + N', ') + @ORD +
            N', t.RRN' + @ORD + N'
          ) AS r;';

    DECLARE @RRN INT, @BUF INT;
    EXEC sp_executesql @SQL,
         N'@MBR VARCHAR(10), @CUR INT, @K1 VARCHAR(256), @K2 VARCHAR(256),
           @K3 VARCHAR(256), @K4 VARCHAR(256), @RRN INT OUTPUT, @BUF INT OUTPUT',
         @MBR, @CUR, @K1, @K2, @K3, @K4, @RRN OUTPUT, @BUF OUTPUT;

    IF @RRN IS NULL
    BEGIN
        -- READE that runs off the end of its key group sets %EOF but does
        -- not move the pointer, so a following READ still works.
        UPDATE QSYS.OPEN_FILE
           SET F_EOF = 1,
               POSSTATE = CASE WHEN @NKEYS > 0 THEN POSSTATE
                               WHEN @PRIOR = 1 THEN 'BOF' ELSE 'EOF' END,
               CURRRN   = CASE WHEN @NKEYS > 0 THEN CURRRN ELSE NULL END
         WHERE OPENID = @OPENID;
        RETURN;
    END;

    EXEC QSYS.RLA_FILLBUF @OPENID, @RRN;

    UPDATE QSYS.OPEN_FILE
       SET POSSTATE = 'AT', CURRRN = @RRN, F_FOUND = 1
     WHERE OPENID = @OPENID;
END;
GO

/*---------------------------------------------------------------------------
  Load one record into the buffer.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.RLA_FILLBUF @OPENID INT, @RRN INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10);
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    DELETE QSYS.RECORD_BUF WHERE OPENID = @OPENID;

    DECLARE @SQL NVARCHAR(MAX) =
        N'INSERT QSYS.RECORD_BUF (OPENID, FLDNAME, VAL)
          SELECT @O, V.FLDNAME, V.VAL
          FROM   ' + @TBL + N' AS r
          CROSS APPLY (VALUES
            ' + QSYS.RLA_BUFLIST(@FMTID) + N'
          ) AS V (FLDNAME, VAL)
          WHERE  r.MBRNAME = @MBR AND r.RRN = @RRN;';

    EXEC sp_executesql @SQL,
         N'@O INT, @MBR VARCHAR(10), @RRN INT', @OPENID, @MBR, @RRN;
END;
GO

/*===========================================================================
  CHAIN — random read by key. The one everybody remembers.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.CHAIN
    @OPENID INT,
    @K1 VARCHAR(256) = NULL, @K2 VARCHAR(256) = NULL,
    @K3 VARCHAR(256) = NULL, @K4 VARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.RLA_BEGIN @OPENID, @OP = '*CHAIN';

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10);
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    DECLARE @NKEYS INT =
        CASE WHEN @K4 IS NOT NULL THEN 4 WHEN @K3 IS NOT NULL THEN 3
             WHEN @K2 IS NOT NULL THEN 2 WHEN @K1 IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @SQL NVARCHAR(MAX) =
        N'SELECT TOP (1) @RRN = t.RRN FROM ' + @TBL + N' AS t
          WHERE t.MBRNAME = @MBR' + QSYS.RLA_KEYEQ(@FMTID, @NKEYS, N't') + N'
          ORDER BY t.RRN;';

    DECLARE @RRN INT;
    EXEC sp_executesql @SQL,
         N'@MBR VARCHAR(10), @K1 VARCHAR(256), @K2 VARCHAR(256),
           @K3 VARCHAR(256), @K4 VARCHAR(256), @RRN INT OUTPUT',
         @MBR, @K1, @K2, @K3, @K4, @RRN OUTPUT;

    IF @RRN IS NULL
    BEGIN
        -- A failed CHAIN leaves the pointer where it was, and %FOUND off.
        UPDATE QSYS.OPEN_FILE SET F_FOUND = 0 WHERE OPENID = @OPENID;
        RETURN;
    END;

    EXEC QSYS.RLA_FILLBUF @OPENID, @RRN;

    UPDATE QSYS.OPEN_FILE
       SET POSSTATE = 'AT', CURRRN = @RRN, F_FOUND = 1, F_EQUAL = 1
     WHERE OPENID = @OPENID;
END;
GO

/*===========================================================================
  WRITE / UPDATE / DELETE — the buffer is the record.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.WRITE_REC
    @OPENID INT,
    @VALUES QSYS.FIELD_VALUES READONLY
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.RLA_BEGIN @OPENID, @OP = '*WRITE';

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10);
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    DECLARE @COLS NVARCHAR(MAX), @VALS NVARCHAR(MAX);

    SELECT @COLS = STRING_AGG(CAST(QUOTENAME(F.FLDNAME) AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY F.FLDSEQ),
           @VALS = STRING_AGG(CAST(
                       N'CAST(' + ISNULL(N'''' + REPLACE(V.VAL, N'''', N'''''') + N'''', N'NULL') +
                       N' AS ' + QSYS.DDS_SQLTYPE(F.DTYPE, F.FLDLEN, F.DECPOS) + N')'
                       AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY F.FLDSEQ)
    FROM   QSYS.FIELD AS F
    LEFT JOIN @VALUES AS V ON V.FLDNAME = F.FLDNAME AND V.RRN = 0
    WHERE  F.FMTID = @FMTID;

    DECLARE @SQL NVARCHAR(MAX) =
        N'INSERT ' + @TBL + N' (MBRNAME, ' + @COLS + N')
          VALUES (@MBR, ' + @VALS + N');
          SELECT @RRN = SCOPE_IDENTITY();';

    DECLARE @RRN INT;
    EXEC sp_executesql @SQL, N'@MBR VARCHAR(10), @RRN INT OUTPUT', @MBR, @RRN OUTPUT;

    EXEC QSYS.RLA_FILLBUF @OPENID, @RRN;
    UPDATE QSYS.OPEN_FILE SET POSSTATE = 'AT', CURRRN = @RRN, F_FOUND = 1
     WHERE OPENID = @OPENID;
END;
GO

CREATE OR ALTER PROCEDURE QSYS.UPDATE_REC
    @OPENID INT,
    @VALUES QSYS.FIELD_VALUES READONLY
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FMTID INT, @TBL NVARCHAR(256), @MBR VARCHAR(10),
            @POS VARCHAR(10), @CUR INT;
    SELECT @FMTID = FMTID, @TBL = BASETABLE, @MBR = MBRNAME,
           @POS = POSSTATE, @CUR = CURRRN
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    -- UPDATE only works on a record you have actually read. CPF5030.
    IF @POS <> 'AT' OR @CUR IS NULL
    BEGIN
        UPDATE QSYS.OPEN_FILE SET F_ERROR = 1, LASTOP = '*UPDATE' WHERE OPENID = @OPENID;
        THROW 50062, N'CPF5030 - No record read for update.', 1;
    END;

    EXEC QSYS.RLA_BEGIN @OPENID, @OP = '*UPDATE';

    DECLARE @SET NVARCHAR(MAX) =
    (
        SELECT STRING_AGG(CAST(
                   QUOTENAME(F.FLDNAME) + N' = CAST(' +
                   ISNULL(N'''' + REPLACE(V.VAL, N'''', N'''''') + N'''', N'NULL') +
                   N' AS ' + QSYS.DDS_SQLTYPE(F.DTYPE, F.FLDLEN, F.DECPOS) + N')'
                   AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY F.FLDSEQ)
        FROM   QSYS.FIELD AS F
        JOIN   @VALUES AS V ON V.FLDNAME = F.FLDNAME AND V.RRN = 0
        WHERE  F.FMTID = @FMTID
    );

    IF @SET IS NULL RETURN;

    DECLARE @SQL NVARCHAR(MAX) =
        N'UPDATE ' + @TBL + N' SET ' + @SET +
        N' WHERE MBRNAME = @MBR AND RRN = @RRN;';

    EXEC sp_executesql @SQL, N'@MBR VARCHAR(10), @RRN INT', @MBR, @CUR;

    EXEC QSYS.RLA_FILLBUF @OPENID, @CUR;
    UPDATE QSYS.OPEN_FILE SET POSSTATE = 'AT', CURRRN = @CUR, F_FOUND = 1
     WHERE OPENID = @OPENID;
END;
GO

CREATE OR ALTER PROCEDURE QSYS.DELETE_REC @OPENID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TBL NVARCHAR(256), @MBR VARCHAR(10), @POS VARCHAR(10), @CUR INT;
    SELECT @TBL = BASETABLE, @MBR = MBRNAME, @POS = POSSTATE, @CUR = CURRRN
    FROM   QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    IF @POS <> 'AT' OR @CUR IS NULL
    BEGIN
        UPDATE QSYS.OPEN_FILE SET F_ERROR = 1, LASTOP = '*DELETE' WHERE OPENID = @OPENID;
        THROW 50063, N'CPF5030 - No record read for delete.', 1;
    END;

    DECLARE @FMTID INT;
    SELECT @FMTID = FMTID FROM QSYS.OPEN_FILE WHERE OPENID = @OPENID;

    EXEC QSYS.RLA_BEGIN @OPENID, @OP = '*DELETE';

    /*  Step the pointer back to the PRIOR record BEFORE removing this one.
        Position is a relative record number, so leaving it on the record we
        are about to delete would give the next READ nothing to compare
        against — a false end of file that stops a read-and-delete loop dead
        after its first record.                                            */
    DECLARE @PRIORSQL NVARCHAR(MAX) =
        N'SELECT TOP (1) @P = t.RRN FROM ' + @TBL + N' AS t
          CROSS JOIN (SELECT * FROM ' + @TBL + N'
                      WHERE MBRNAME = @MBR AND RRN = @RRN) AS c
          WHERE t.MBRNAME = @MBR AND ' + QSYS.RLA_TUPLE(@FMTID, N'PRIOR') + N'
          ORDER BY ' +
          REPLACE(QSYS.RLA_KEYLIST(@FMTID, N't.'), N', ', N' DESC, ') +
          N' DESC, t.RRN DESC;';

    DECLARE @PRIOR INT;
    EXEC sp_executesql @PRIORSQL,
         N'@MBR VARCHAR(10), @RRN INT, @P INT OUTPUT', @MBR, @CUR, @PRIOR OUTPUT;

    DECLARE @SQL NVARCHAR(MAX) =
        N'DELETE FROM ' + @TBL + N' WHERE MBRNAME = @MBR AND RRN = @RRN;';
    EXEC sp_executesql @SQL, N'@MBR VARCHAR(10), @RRN INT', @MBR, @CUR;

    UPDATE QSYS.OPEN_FILE
       SET F_FOUND  = 1,
           POSSTATE = CASE WHEN @PRIOR IS NULL THEN 'BOF' ELSE 'AT' END,
           CURRRN   = @PRIOR
     WHERE OPENID = @OPENID;
END;
GO

/*---------------------------------------------------------------------------
  Convenience: the buffer, shaped for QSYS.RENDER.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.BUF (@OPENID INT)
RETURNS TABLE
AS
RETURN (SELECT FLDNAME, VAL FROM QSYS.RECORD_BUF WHERE OPENID = @OPENID);
GO

/*---------------------------------------------------------------------------
  Indicators, for readability at the call site.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.PCT_EOF   (@O INT) RETURNS BIT AS
BEGIN RETURN (SELECT F_EOF   FROM QSYS.OPEN_FILE WHERE OPENID = @O); END;
GO
CREATE OR ALTER FUNCTION QSYS.PCT_FOUND (@O INT) RETURNS BIT AS
BEGIN RETURN (SELECT F_FOUND FROM QSYS.OPEN_FILE WHERE OPENID = @O); END;
GO
CREATE OR ALTER FUNCTION QSYS.PCT_EQUAL (@O INT) RETURNS BIT AS
BEGIN RETURN (SELECT F_EQUAL FROM QSYS.OPEN_FILE WHERE OPENID = @O); END;
GO
