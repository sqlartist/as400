/*===========================================================================
  AS/400 in SQL Server 2025  —  02: the DDS compiler
  ---------------------------------------------------------------------------
  DDS is column-positional, which is the single most helpful fact about this
  whole project. There is no grammar to fight: the meaning of a character is
  decided by where it sits. So the "parser" is SUBSTRING at fixed offsets.

  DDS statement layout (positions within the 80-byte source statement):

      1-5    Sequence number
      6      Form type            'A'
      7      Comment              '*'
      8-16   Conditioning         (indicators)
      17     Name type            R = record format, K = key, blank = field
      18     Reserved
      19-28  Name
      29-30  Reference
      31-34  Length
      35     Data type            A P S B L T
      36-37  Decimal positions
      38     Usage                B I O
      39-41  Location: line       (display files)
      42-44  Location: position   (display files)
      45-80  Functions            keywords and constants
===========================================================================*/

/*---------------------------------------------------------------------------
  Split one DDS statement into its positional parts.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.DDS_SPLIT (@SRCDTA VARCHAR(100))
RETURNS TABLE
AS
RETURN
(
    SELECT
        FORMTYPE = SUBSTRING(L, 6, 1),
        ISCOMMENT= CASE WHEN SUBSTRING(L, 7, 1) = '*' THEN 1 ELSE 0 END,
        COND     = RTRIM(SUBSTRING(L, 8, 9)),
        NAMETYPE = SUBSTRING(L, 17, 1),
        NAME     = UPPER(RTRIM(LTRIM(SUBSTRING(L, 19, 10)))),
        REFFLD   = RTRIM(SUBSTRING(L, 29, 2)),
        FLDLENT  = RTRIM(LTRIM(SUBSTRING(L, 31, 4))),
        DTYPE    = SUBSTRING(L, 35, 1),
        DECPOST  = RTRIM(LTRIM(SUBSTRING(L, 36, 2))),
        USAGE    = SUBSTRING(L, 38, 1),
        LINT     = RTRIM(LTRIM(SUBSTRING(L, 39, 3))),
        POST     = RTRIM(LTRIM(SUBSTRING(L, 42, 3))),
        FUNCS    = RTRIM(SUBSTRING(L, 45, 36))
    FROM (SELECT L = LEFT(@SRCDTA + REPLICATE(' ', 80), 80)) AS P
);
GO

/*---------------------------------------------------------------------------
  Pull KEYWORD(argument) out of the functions area.
  Returns NULL when the keyword is absent, '' when present with no argument.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.DDS_KEYWORD (@FUNCS VARCHAR(4000), @KWD VARCHAR(20))
RETURNS VARCHAR(4000)
AS
BEGIN
    -- Search case-insensitively but slice from the ORIGINAL, so that
    -- TEXT('Part master record') keeps its case instead of shouting.
    DECLARE @F VARCHAR(4000) = ' ' + LTRIM(RTRIM(ISNULL(@FUNCS, '')));
    DECLARE @U VARCHAR(4000) = UPPER(@F);
    DECLARE @K VARCHAR(40)   = ' ' + UPPER(@KWD);
    DECLARE @AT INT          = CHARINDEX(@K, @U);

    IF @AT = 0 RETURN NULL;

    DECLARE @AFTER INT = @AT + LEN(@K);              -- first char after keyword
    IF @AFTER > LEN(@U) RETURN '';                   -- keyword with no argument
    IF SUBSTRING(@U, @AFTER, 1) <> '(' RETURN '';    -- keyword with no argument

    -- walk to the matching close paren
    DECLARE @I INT = @AFTER + 1, @DEPTH INT = 1, @LEN INT = LEN(@U), @C CHAR(1);
    WHILE @I <= @LEN AND @DEPTH > 0
    BEGIN
        SET @C = SUBSTRING(@U, @I, 1);
        IF @C = '(' SET @DEPTH = @DEPTH + 1;
        IF @C = ')' SET @DEPTH = @DEPTH - 1;
        IF @DEPTH > 0 SET @I = @I + 1;
    END;

    RETURN SUBSTRING(@F, @AFTER + 1, @I - @AFTER - 1);
END;
GO

/*---------------------------------------------------------------------------
  Pull a leading quoted literal out of the functions area — a screen constant.
  Doubled quotes inside the literal are unescaped, as DDS requires.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.DDS_CONSTANT (@FUNCS VARCHAR(4000))
RETURNS VARCHAR(80)
AS
BEGIN
    DECLARE @F VARCHAR(4000) = LTRIM(RTRIM(ISNULL(@FUNCS, '')));
    IF LEFT(@F, 1) <> '''' RETURN NULL;

    DECLARE @I INT = 2, @LEN INT = LEN(@F), @OUT VARCHAR(80) = '', @C CHAR(1);
    WHILE @I <= @LEN
    BEGIN
        SET @C = SUBSTRING(@F, @I, 1);
        IF @C = ''''
        BEGIN
            IF SUBSTRING(@F, @I + 1, 1) = ''''      -- '' is a literal quote
            BEGIN
                SET @OUT = @OUT + '''';
                SET @I = @I + 2;
                CONTINUE;
            END;
            BREAK;                                   -- closing quote
        END;
        SET @OUT = @OUT + @C;
        SET @I = @I + 1;
    END;

    RETURN @OUT;
END;
GO

/*---------------------------------------------------------------------------
  Map a DDS data type to a SQL Server type.

  Note on P and S: these are packed and zoned decimal, and on a real machine
  they are byte layouts, not numbers — which is what lets RPG overlay a
  packed field with characters in a data structure. We map them to DECIMAL
  for now. The byte-accurate record image belongs with the RPG work.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.DDS_SQLTYPE (@DTYPE CHAR(1), @LEN SMALLINT, @DEC SMALLINT)
RETURNS NVARCHAR(50)
AS
BEGIN
    RETURN CASE UPPER(@DTYPE)
        WHEN 'A' THEN N'CHAR(' + CAST(@LEN AS NVARCHAR(10)) + N')'
        WHEN 'P' THEN N'DECIMAL(' + CAST(@LEN AS NVARCHAR(10)) + N',' + CAST(ISNULL(@DEC,0) AS NVARCHAR(10)) + N')'
        WHEN 'S' THEN N'DECIMAL(' + CAST(@LEN AS NVARCHAR(10)) + N',' + CAST(ISNULL(@DEC,0) AS NVARCHAR(10)) + N')'
        WHEN 'B' THEN CASE WHEN @LEN <= 4 THEN N'SMALLINT' WHEN @LEN <= 9 THEN N'INT' ELSE N'BIGINT' END
        WHEN 'L' THEN N'DATE'
        WHEN 'T' THEN N'TIME(0)'
        WHEN 'Z' THEN N'DATETIME2(6)'
        ELSE N'CHAR(' + CAST(@LEN AS NVARCHAR(10)) + N')'
    END;
END;
GO

/*===========================================================================
  CRTPF — create a physical file from DDS.

  Reads the source member, populates the catalog, and builds the real table
  that holds the data. Every record gets a member name and a relative record
  number, because on the machine every record has both.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.CRTPF
    @LIBNAME VARCHAR(10),
    @FILENAME VARCHAR(10),
    @SRCLIB  VARCHAR(10) = NULL,
    @SRCFILE VARCHAR(10) = 'QDDSSRC',
    @SRCMBR  VARCHAR(10) = NULL,
    @TEXT    VARCHAR(50) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @LIBNAME = UPPER(@LIBNAME);
    SET @FILENAME = UPPER(@FILENAME);
    SET @SRCLIB  = UPPER(ISNULL(@SRCLIB, @LIBNAME));
    SET @SRCMBR  = UPPER(ISNULL(@SRCMBR, @FILENAME));

    IF EXISTS (SELECT 1 FROM QSYS.OBJECT
               WHERE LIBNAME = @LIBNAME AND OBJNAME = @FILENAME AND OBJTYPE = '*FILE')
        THROW 50020, N'CPF3208 - File already exists in library.', 1;

    BEGIN TRY
    BEGIN TRAN;

    ------------------------------------------------------------------ parse
    DROP TABLE IF EXISTS #DDS;
    SELECT S.SRCSEQ, D.*
    INTO   #DDS
    FROM   QSYS.SRC_MBR AS S
    CROSS APPLY QSYS.DDS_SPLIT(S.SRCDTA) AS D
    WHERE  S.LIBNAME = @SRCLIB AND S.SRCFILE = @SRCFILE AND S.MBRNAME = @SRCMBR
      AND  D.ISCOMMENT = 0;

    IF NOT EXISTS (SELECT 1 FROM #DDS)
        THROW 50021, N'CPF7310 - Source member not found or empty.', 1;

    ---------------------------------------------------------------- object
    DECLARE @OBJID INT;
    EXEC QSYS.CRTOBJ @LIBNAME, @FILENAME, '*FILE', 'PF', @TEXT, @OBJID OUTPUT;

    DECLARE @TBL NVARCHAR(256) =
        QUOTENAME(@LIBNAME) + N'.' + QUOTENAME(@FILENAME);

    INSERT QSYS.[FILE] (OBJID, FILETYPE, BASETABLE) VALUES (@OBJID, 'PF', @TBL);
    INSERT QSYS.FILE_MEMBER (OBJID, MBRNAME) VALUES (@OBJID, @FILENAME);

    --------------------------------------------------------- record format
    DECLARE @FMTNAME VARCHAR(10) =
        (SELECT TOP (1) NAME FROM #DDS WHERE NAMETYPE = 'R' ORDER BY SRCSEQ);

    IF @FMTNAME IS NULL
        THROW 50022, N'CPF7304 - No record format found in DDS source.', 1;

    DECLARE @FMTID INT;
    INSERT QSYS.RECORD_FORMAT (OBJID, FMTNAME, FMTSEQ, FMTKIND, TEXT)
    VALUES (@OBJID, @FMTNAME, 1, 'RECORD', @TEXT);
    SET @FMTID = SCOPE_IDENTITY();

    ---------------------------------------------------------------- fields
    INSERT QSYS.FIELD (FMTID, FLDSEQ, FLDNAME, DTYPE, FLDLEN, DECPOS, COLHDG, TEXT)
    SELECT @FMTID,
           ROW_NUMBER() OVER (ORDER BY SRCSEQ),
           NAME,
           CASE WHEN DTYPE = ' ' THEN 'A' ELSE UPPER(DTYPE) END,
           TRY_CAST(FLDLENT AS SMALLINT),
           TRY_CAST(DECPOST AS SMALLINT),
           ISNULL(QSYS.DDS_KEYWORD(FUNCS, 'COLHDG'), ''),
           ISNULL(QSYS.DDS_KEYWORD(FUNCS, 'TEXT'), '')
    FROM   #DDS
    WHERE  NAMETYPE = ' ' AND NAME <> '' AND FLDLENT <> '';

    ------------------------------------------------------------------ keys
    WITH K AS
    (
        SELECT NAME, KEYSEQ = ROW_NUMBER() OVER (ORDER BY SRCSEQ)
        FROM   #DDS WHERE NAMETYPE = 'K' AND NAME <> ''
    )
    UPDATE F
       SET F.ISKEY = 1, F.KEYSEQ = K.KEYSEQ
    FROM   QSYS.FIELD AS F
    JOIN   K ON K.NAME = F.FLDNAME
    WHERE  F.FMTID = @FMTID;

    UPDATE QSYS.[FILE]
       SET RECLEN = (SELECT SUM(FLDLEN) FROM QSYS.FIELD WHERE FMTID = @FMTID)
     WHERE OBJID = @OBJID;

    ------------------------------------------------- build the data table
    IF SCHEMA_ID(@LIBNAME) IS NULL
        EXEC (N'CREATE SCHEMA ' + @LIBNAME);

    DECLARE @COLS NVARCHAR(MAX) =
    (
        SELECT STRING_AGG(
                   CAST(N'    ' + QUOTENAME(FLDNAME) + N' ' +
                        QSYS.DDS_SQLTYPE(DTYPE, FLDLEN, DECPOS) + N' NULL'
                        AS NVARCHAR(MAX)), N',' + CHAR(13) + CHAR(10))
               WITHIN GROUP (ORDER BY FLDSEQ)
        FROM   QSYS.FIELD WHERE FMTID = @FMTID
    );

    DECLARE @KEYCOLS NVARCHAR(MAX) =
    (
        SELECT STRING_AGG(CAST(QUOTENAME(FLDNAME) AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY KEYSEQ)
        FROM   QSYS.FIELD WHERE FMTID = @FMTID AND ISKEY = 1
    );

    DECLARE @SQL NVARCHAR(MAX) =
        N'CREATE TABLE ' + @TBL + N'
(
    MBRNAME CHAR(10)      NOT NULL DEFAULT ''' + @FILENAME + N''',
    RRN     INT IDENTITY(1,1) NOT NULL,
' + @COLS + N',
    CONSTRAINT ' + QUOTENAME(N'PK_' + @LIBNAME + N'_' + @FILENAME) +
        N' PRIMARY KEY NONCLUSTERED (MBRNAME, RRN)
);';

    EXEC sp_executesql @SQL;

    -- A keyed physical file is an index. Access path = clustered index.
    IF @KEYCOLS IS NOT NULL
    BEGIN
        SET @SQL = N'CREATE CLUSTERED INDEX ' +
                   QUOTENAME(N'AP_' + @LIBNAME + N'_' + @FILENAME) +
                   N' ON ' + @TBL + N' (MBRNAME, ' + @KEYCOLS + N');';
        EXEC sp_executesql @SQL;
    END;

    COMMIT;
    PRINT 'CPC7301 - File ' + @FILENAME + ' created in library ' + @LIBNAME + '.';
    END TRY
    BEGIN CATCH
        -- A failed create leaves nothing behind, as on the machine.
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/*===========================================================================
  CRTDSPF — create a display file from DDS.

  Display file DDS is the same column layout, but positions 39-44 now mean
  something: where on the screen this goes. That is the whole renderer
  contract, and it is why a 5250 screen is a projection, not a drawing.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.CRTDSPF
    @LIBNAME VARCHAR(10),
    @FILENAME VARCHAR(10),
    @SRCLIB  VARCHAR(10) = NULL,
    @SRCFILE VARCHAR(10) = 'QDDSSRC',
    @SRCMBR  VARCHAR(10) = NULL,
    @TEXT    VARCHAR(50) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @LIBNAME  = UPPER(@LIBNAME);
    SET @FILENAME = UPPER(@FILENAME);
    SET @SRCLIB   = UPPER(ISNULL(@SRCLIB, @LIBNAME));
    SET @SRCMBR   = UPPER(ISNULL(@SRCMBR, @FILENAME));

    IF EXISTS (SELECT 1 FROM QSYS.OBJECT
               WHERE LIBNAME = @LIBNAME AND OBJNAME = @FILENAME AND OBJTYPE = '*FILE')
        THROW 50020, N'CPF3208 - File already exists in library.', 1;

    BEGIN TRY
    BEGIN TRAN;

    ------------------------------------------------------------------ parse
    DROP TABLE IF EXISTS #D;
    SELECT S.SRCSEQ, D.*
    INTO   #D
    FROM   QSYS.SRC_MBR AS S
    CROSS APPLY QSYS.DDS_SPLIT(S.SRCDTA) AS D
    WHERE  S.LIBNAME = @SRCLIB AND S.SRCFILE = @SRCFILE AND S.MBRNAME = @SRCMBR
      AND  D.ISCOMMENT = 0;

    IF NOT EXISTS (SELECT 1 FROM #D)
        THROW 50021, N'CPF7310 - Source member not found or empty.', 1;

    ---------------------------------------------------------------- object
    DECLARE @OBJID INT;
    EXEC QSYS.CRTOBJ @LIBNAME, @FILENAME, '*FILE', 'DSPF', @TEXT, @OBJID OUTPUT;

    -- DSPSIZ is a file-level keyword: it appears before the first R spec.
    DECLARE @FIRSTR DECIMAL(6,2) =
        (SELECT MIN(SRCSEQ) FROM #D WHERE NAMETYPE = 'R');

    DECLARE @DSPSIZ VARCHAR(100) =
    (
        SELECT TOP (1) QSYS.DDS_KEYWORD(FUNCS, 'DSPSIZ')
        FROM   #D
        -- 9999.99 is the sentinel, not 999999: SRCSEQ is DECIMAL(6,2), which
        -- is exactly SEU's own limit, and a bigger literal overflows it.
        WHERE  SRCSEQ < ISNULL(@FIRSTR, 9999.99)
          AND  QSYS.DDS_KEYWORD(FUNCS, 'DSPSIZ') IS NOT NULL
        ORDER BY SRCSEQ
    );

    INSERT QSYS.[FILE] (OBJID, FILETYPE, DSPSIZ_ROWS, DSPSIZ_COLS)
    VALUES (@OBJID, 'DSPF',
            ISNULL(TRY_CAST(PARSENAME(REPLACE(LTRIM(@DSPSIZ), ' ', '.'), 3) AS SMALLINT), 24),
            ISNULL(TRY_CAST(PARSENAME(REPLACE(LTRIM(@DSPSIZ), ' ', '.'), 2) AS SMALLINT), 80));

    -------------------------------------------------------- record formats
    -- Each R spec opens a format; everything after it belongs to it until
    -- the next R spec.
    DROP TABLE IF EXISTS #FMT;
    SELECT FMTSEQ  = ROW_NUMBER() OVER (ORDER BY SRCSEQ),
           FMTNAME = NAME,
           STARTSEQ= SRCSEQ,
           ENDSEQ  = LEAD(SRCSEQ) OVER (ORDER BY SRCSEQ),
           FUNCS
    INTO   #FMT
    FROM   #D
    WHERE  NAMETYPE = 'R';

    DECLARE @FMTSEQ INT = 1, @MAXFMT INT = (SELECT MAX(FMTSEQ) FROM #FMT);

    WHILE @FMTSEQ <= @MAXFMT
    BEGIN
        DECLARE @FMTNAME  VARCHAR(10),
                @STARTSEQ DECIMAL(6,2),
                @ENDSEQ   DECIMAL(6,2),
                @FFUNCS   VARCHAR(4000);

        SELECT @FMTNAME = FMTNAME, @STARTSEQ = STARTSEQ,
               @ENDSEQ = ISNULL(ENDSEQ, 9999.99), @FFUNCS = FUNCS
        FROM   #FMT WHERE FMTSEQ = @FMTSEQ;

        -- Format-level keywords can continue on the lines that follow the
        -- R spec: any line with no name and no screen position.
        SET @FFUNCS = @FFUNCS + ' ' + ISNULL(
        (
            SELECT STRING_AGG(CAST(FUNCS AS VARCHAR(MAX)), ' ')
                   WITHIN GROUP (ORDER BY SRCSEQ)
            FROM   #D
            WHERE  SRCSEQ > @STARTSEQ AND SRCSEQ < @ENDSEQ
              AND  NAMETYPE = ' ' AND NAME = '' AND LINT = '' AND POST = ''
              AND  FUNCS <> ''
        ), '');

        DECLARE @KIND VARCHAR(10) =
            CASE WHEN QSYS.DDS_KEYWORD(@FFUNCS, 'SFLCTL') IS NOT NULL THEN 'SFLCTL'
                 WHEN QSYS.DDS_KEYWORD(@FFUNCS, 'SFL')    IS NOT NULL THEN 'SFL'
                 ELSE 'RECORD' END;

        DECLARE @FMTID2 INT;
        INSERT QSYS.RECORD_FORMAT (OBJID, FMTNAME, FMTSEQ, FMTKIND, SFL_FMT, SFLPAG, SFLSIZ)
        VALUES (@OBJID, @FMTNAME, @FMTSEQ, @KIND,
                NULLIF(UPPER(LTRIM(RTRIM(ISNULL(QSYS.DDS_KEYWORD(@FFUNCS, 'SFLCTL'), '')))), ''),
                TRY_CAST(QSYS.DDS_KEYWORD(@FFUNCS, 'SFLPAG') AS SMALLINT),
                TRY_CAST(QSYS.DDS_KEYWORD(@FFUNCS, 'SFLSIZ') AS SMALLINT));
        SET @FMTID2 = SCOPE_IDENTITY();

        ------------------------------------------------------ screen fields
        INSERT QSYS.DSPF_FIELD
            (FMTID, FLDSEQ, FLDKIND, FLDNAME, DTYPE, FLDLEN, DECPOS,
             USAGE, LIN, POS, CONSTANT, DSPATR, EDTCDE)
        SELECT @FMTID2,
               ROW_NUMBER() OVER (ORDER BY SRCSEQ),
               CASE WHEN NAME = '' THEN 'C' ELSE 'F' END,
               NAME,
               CASE WHEN DTYPE = ' ' THEN 'A' ELSE UPPER(DTYPE) END,
               ISNULL(TRY_CAST(FLDLENT AS SMALLINT),
                      ISNULL(LEN(QSYS.DDS_CONSTANT(FUNCS)), 0)),
               TRY_CAST(DECPOST AS SMALLINT),
               CASE WHEN USAGE IN ('I','O','B') THEN USAGE ELSE 'O' END,
               TRY_CAST(LINT AS SMALLINT),
               TRY_CAST(POST AS SMALLINT),
               QSYS.DDS_CONSTANT(FUNCS),
               ISNULL(QSYS.DDS_KEYWORD(FUNCS, 'DSPATR'), ''),
               ISNULL(QSYS.DDS_KEYWORD(FUNCS, 'EDTCDE'), '')
        FROM   #D
        WHERE  SRCSEQ > @STARTSEQ AND SRCSEQ < @ENDSEQ
          AND  NAMETYPE = ' '
          AND  TRY_CAST(LINT AS SMALLINT) IS NOT NULL
          AND  TRY_CAST(POST AS SMALLINT) IS NOT NULL;

        SET @FMTSEQ = @FMTSEQ + 1;
    END;

    COMMIT;
    PRINT 'CPC7301 - Display file ' + @FILENAME + ' created in library ' + @LIBNAME + '.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
