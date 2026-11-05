/*===========================================================================
  AS/400 in SQL Server 2025  —  04: Control Language
  ---------------------------------------------------------------------------
  A CL command is an object with a parameter list. That is why the machine
  could prompt any command with F4 without knowing anything about it: the
  prompter reads the *CMD object, not the program behind it. We keep that
  separation — QSYS.COMMAND_PARM is the prompt, CMDPROC is the implementation.

  Syntax handled:   CMDNAME  KWD(value)  KWD(value)
                    CMDNAME  positional  positional
                    CMDNAME  LIB/OBJ     (qualified names)
===========================================================================*/

/*---------------------------------------------------------------------------
  Split a command string into keyword/value pairs.
  Positional values come back with KWD = '' and are matched to parameters in
  declaration order by the dispatcher.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.CL_PARSE (@CMD VARCHAR(4000))
RETURNS @OUT TABLE (SEQ INT, KWD VARCHAR(10), VAL VARCHAR(256))
AS
BEGIN
    DECLARE @S VARCHAR(4000) = LTRIM(RTRIM(ISNULL(@CMD, '')));
    DECLARE @LEN INT = LEN(@S), @I INT = 1, @SEQ INT = 0;
    DECLARE @TOK VARCHAR(256) = '', @C CHAR(1);

    -- step past the command name
    WHILE @I <= @LEN AND SUBSTRING(@S, @I, 1) <> ' ' SET @I = @I + 1;

    WHILE @I <= @LEN
    BEGIN
        -- skip blanks
        WHILE @I <= @LEN AND SUBSTRING(@S, @I, 1) = ' ' SET @I = @I + 1;
        IF @I > @LEN BREAK;

        -- read a token up to '(' or blank
        SET @TOK = '';
        WHILE @I <= @LEN
        BEGIN
            SET @C = SUBSTRING(@S, @I, 1);
            IF @C IN (' ', '(') BREAK;
            SET @TOK = @TOK + @C;
            SET @I = @I + 1;
        END;

        SET @SEQ = @SEQ + 1;

        IF @I <= @LEN AND SUBSTRING(@S, @I, 1) = '('
        BEGIN
            -- KWD(value) — walk to the matching close paren
            DECLARE @DEPTH INT = 1, @VAL VARCHAR(256) = '';
            SET @I = @I + 1;
            WHILE @I <= @LEN AND @DEPTH > 0
            BEGIN
                SET @C = SUBSTRING(@S, @I, 1);
                IF @C = '(' SET @DEPTH = @DEPTH + 1;
                IF @C = ')' SET @DEPTH = @DEPTH - 1;
                IF @DEPTH > 0 SET @VAL = @VAL + @C;
                SET @I = @I + 1;
            END;
            INSERT @OUT VALUES (@SEQ, UPPER(@TOK), LTRIM(RTRIM(@VAL)));
        END
        ELSE
        BEGIN
            -- a bare positional value
            INSERT @OUT VALUES (@SEQ, '', LTRIM(RTRIM(@TOK)));
        END;
    END;

    RETURN;
END;
GO

/*---------------------------------------------------------------------------
  Qualified name helpers:  LIB/OBJ  ->  library, object
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.QUAL_LIB (@Q VARCHAR(100), @DFT VARCHAR(10))
RETURNS VARCHAR(10)
AS
BEGIN
    RETURN UPPER(CASE WHEN CHARINDEX('/', @Q) > 0
                      THEN LEFT(@Q, CHARINDEX('/', @Q) - 1)
                      ELSE @DFT END);
END;
GO

CREATE OR ALTER FUNCTION QSYS.QUAL_OBJ (@Q VARCHAR(100))
RETURNS VARCHAR(10)
AS
BEGIN
    RETURN UPPER(CASE WHEN CHARINDEX('/', @Q) > 0
                      THEN SUBSTRING(@Q, CHARINDEX('/', @Q) + 1, 10)
                      ELSE @Q END);
END;
GO

/*===========================================================================
  The commands themselves.
===========================================================================*/

CREATE OR ALTER PROCEDURE QSYS.CMD_CRTLIB
    @LIB VARCHAR(10), @TEXT VARCHAR(50) = ''
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM QSYS.LIBRARY WHERE LIBNAME = UPPER(@LIB))
        THROW 50040, N'CPF2111 - Library already exists.', 1;
    INSERT QSYS.LIBRARY (LIBNAME, TEXT) VALUES (UPPER(@LIB), @TEXT);
    PRINT 'CPC2102 - Library ' + UPPER(@LIB) + ' created.';
END;
GO

CREATE OR ALTER PROCEDURE QSYS.CMD_WRKLIB
    @LIB VARCHAR(10) = '*ALL'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  Library = L.LIBNAME,
            Type    = L.LIBTYPE,
            Objects = (SELECT COUNT(*) FROM QSYS.OBJECT AS O WHERE O.LIBNAME = L.LIBNAME),
            Text    = L.TEXT
    FROM    QSYS.LIBRARY AS L
    WHERE   UPPER(@LIB) = '*ALL' OR L.LIBNAME LIKE REPLACE(UPPER(@LIB), '*', '%')
    ORDER BY L.LIBNAME;
END;
GO

CREATE OR ALTER PROCEDURE QSYS.CMD_WRKOBJ
    @OBJ VARCHAR(100) = '*ALL', @OBJTYPE VARCHAR(10) = '*ALL'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @L VARCHAR(10) = QSYS.QUAL_LIB(@OBJ, '*ALL');
    DECLARE @O VARCHAR(10) = QSYS.QUAL_OBJ(@OBJ);

    SELECT  [Object]  = O.OBJNAME,
            Library   = O.LIBNAME,
            [Type]    = O.OBJTYPE,
            Attribute = O.OBJATTR,
            Text      = O.TEXT
    FROM    QSYS.OBJECT AS O
    WHERE   (@L = '*ALL' OR O.LIBNAME = @L)
      AND   (@O = '*ALL' OR O.OBJNAME LIKE REPLACE(@O, '*', '%'))
      AND   (UPPER(@OBJTYPE) = '*ALL' OR O.OBJTYPE = UPPER(@OBJTYPE))
    ORDER BY O.LIBNAME, O.OBJNAME;
END;
GO

/*---------------------------------------------------------------------------
  DSPFFD — display file field description. The one everybody actually used.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.CMD_DSPFFD
    @FILE VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @L VARCHAR(10) = QSYS.QUAL_LIB(@FILE, '*LIBL');
    DECLARE @F VARCHAR(10) = QSYS.QUAL_OBJ(@FILE);

    SELECT  [Record format] = R.FMTNAME,
            [Field]         = FLD.FLDNAME,
            [Type]          = CASE FLD.DTYPE
                                WHEN 'A' THEN 'CHAR'
                                WHEN 'P' THEN 'PACKED'
                                WHEN 'S' THEN 'ZONED'
                                WHEN 'B' THEN 'BINARY'
                                WHEN 'L' THEN 'DATE'
                                WHEN 'T' THEN 'TIME'
                                ELSE FLD.DTYPE END,
            [Length]        = FLD.FLDLEN,
            [Dec]           = FLD.DECPOS,
            [Key]           = CASE WHEN FLD.ISKEY = 1 THEN 'KEY ' + CAST(FLD.KEYSEQ AS VARCHAR(3)) ELSE '' END,
            [Column heading]= FLD.COLHDG,
            [Text]          = FLD.TEXT
    FROM    QSYS.OBJECT AS O
    JOIN    QSYS.[FILE] AS FI  ON FI.OBJID = O.OBJID
    JOIN    QSYS.RECORD_FORMAT AS R ON R.OBJID = O.OBJID
    JOIN    QSYS.FIELD AS FLD  ON FLD.FMTID = R.FMTID
    WHERE   O.OBJNAME = @F AND O.OBJTYPE = '*FILE'
      AND   (@L = '*LIBL' OR O.LIBNAME = @L)
    ORDER BY R.FMTSEQ, FLD.FLDSEQ;
END;
GO

/*---------------------------------------------------------------------------
  DSPPFM — display physical file member.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.CMD_DSPPFM
    @FILE VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @L VARCHAR(10) = QSYS.QUAL_LIB(@FILE, '*LIBL');
    DECLARE @F VARCHAR(10) = QSYS.QUAL_OBJ(@FILE);

    DECLARE @TBL NVARCHAR(256) =
    (
        SELECT TOP (1) FI.BASETABLE
        FROM   QSYS.OBJECT AS O
        JOIN   QSYS.[FILE] AS FI ON FI.OBJID = O.OBJID
        WHERE  O.OBJNAME = @F AND O.OBJTYPE = '*FILE' AND FI.FILETYPE = 'PF'
          AND  (@L = '*LIBL' OR O.LIBNAME = @L)
    );

    IF @TBL IS NULL THROW 50041, N'CPF9812 - File not found.', 1;

    -- sp_executesql takes a variable, not an expression. Build it first.
    DECLARE @SQL NVARCHAR(MAX) = N'SELECT * FROM ' + @TBL + N' ORDER BY RRN;';
    EXEC sp_executesql @SQL;
END;
GO

/*---------------------------------------------------------------------------
  DLTF — delete a file object and everything the catalog knows about it.
  You will want this constantly while you are iterating on DDS.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.CMD_DLTF
    @FILE VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @L VARCHAR(10) = QSYS.QUAL_LIB(@FILE, '*LIBL');
    DECLARE @F VARCHAR(10) = QSYS.QUAL_OBJ(@FILE);

    DECLARE @OBJID INT, @TBL NVARCHAR(256), @LIB VARCHAR(10);
    SELECT TOP (1) @OBJID = O.OBJID, @TBL = FI.BASETABLE, @LIB = O.LIBNAME
    FROM   QSYS.OBJECT AS O
    LEFT JOIN QSYS.[FILE] AS FI ON FI.OBJID = O.OBJID
    WHERE  O.OBJNAME = @F AND O.OBJTYPE = '*FILE'
      AND  (@L = '*LIBL' OR O.LIBNAME = @L);

    IF @OBJID IS NULL THROW 50042, N'CPF2105 - Object not found.', 1;

    BEGIN TRAN;

    DELETE QSYS.DSPF_FIELD
     WHERE FMTID IN (SELECT FMTID FROM QSYS.RECORD_FORMAT WHERE OBJID = @OBJID);
    DELETE QSYS.FIELD
     WHERE FMTID IN (SELECT FMTID FROM QSYS.RECORD_FORMAT WHERE OBJID = @OBJID);
    DELETE QSYS.RECORD_FORMAT WHERE OBJID = @OBJID;
    DELETE QSYS.FILE_MEMBER   WHERE OBJID = @OBJID;
    DELETE QSYS.[FILE]        WHERE OBJID = @OBJID;
    DELETE QSYS.OBJECT        WHERE OBJID = @OBJID;

    IF @TBL IS NOT NULL AND OBJECT_ID(@TBL, N'U') IS NOT NULL
    BEGIN
        DECLARE @SQL NVARCHAR(MAX) = N'DROP TABLE ' + @TBL + N';';
        EXEC sp_executesql @SQL;
    END;

    COMMIT;
    PRINT 'CPC2191 - Object ' + @F + ' in library ' + @LIB + ' type *FILE deleted.';
END;
GO

/*===========================================================================
  Register the commands as *CMD objects, with their parameter lists.
===========================================================================*/
IF NOT EXISTS (SELECT 1 FROM QSYS.LIBRARY WHERE LIBNAME = 'QSYS')
    INSERT QSYS.LIBRARY (LIBNAME, TEXT) VALUES ('QSYS', 'System library');
GO

DECLARE @ID INT;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='CRTLIB')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','CRTLIB','*CMD','','Create Library', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_CRTLIB', 'Create Library');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, REQUIRED) VALUES
        (@ID, 1, 'LIB',  'Library',     1),
        (@ID, 2, 'TEXT', 'Text description', 0);
END;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='WRKLIB')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','WRKLIB','*CMD','','Work with Libraries', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_WRKLIB', 'Work with Libraries');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, DFT) VALUES (@ID, 1, 'LIB', 'Library', '*ALL');
END;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='WRKOBJ')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','WRKOBJ','*CMD','','Work with Objects', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_WRKOBJ', 'Work with Objects');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, DFT) VALUES
        (@ID, 1, 'OBJ',     'Object',      '*ALL'),
        (@ID, 2, 'OBJTYPE', 'Object type', '*ALL');
END;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='DSPFFD')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','DSPFFD','*CMD','','Display File Field Description', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_DSPFFD', 'Display File Field Description');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, REQUIRED) VALUES (@ID, 1, 'FILE', 'File', 1);
END;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='DSPPFM')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','DSPPFM','*CMD','','Display Physical File Member', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_DSPPFM', 'Display Physical File Member');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, REQUIRED) VALUES (@ID, 1, 'FILE', 'File', 1);
END;

IF NOT EXISTS (SELECT 1 FROM QSYS.OBJECT WHERE LIBNAME='QSYS' AND OBJNAME='DLTF')
BEGIN
    EXEC QSYS.CRTOBJ 'QSYS','DLTF','*CMD','','Delete File', @ID OUTPUT;
    INSERT QSYS.COMMAND (OBJID, CMDPROC, PROMPT) VALUES (@ID, 'QSYS.CMD_DLTF', 'Delete File');
    INSERT QSYS.COMMAND_PARM (OBJID, PARMSEQ, KWD, PROMPT, REQUIRED) VALUES (@ID, 1, 'FILE', 'File', 1);
END;
GO

/*===========================================================================
  The command line. Type CL at it.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.CL
    @CMD VARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NAME VARCHAR(10) =
        UPPER(LEFT(LTRIM(@CMD) + ' ', CHARINDEX(' ', LTRIM(@CMD) + ' ') - 1));

    DECLARE @OBJID INT, @PROC NVARCHAR(256);
    SELECT @OBJID = O.OBJID, @PROC = C.CMDPROC
    FROM   QSYS.OBJECT AS O
    JOIN   QSYS.COMMAND AS C ON C.OBJID = O.OBJID
    WHERE  O.OBJNAME = @NAME AND O.OBJTYPE = '*CMD';

    IF @PROC IS NULL
    BEGIN
        DECLARE @M NVARCHAR(200) = N'CPF0006 - Command ' + @NAME + N' not found.';
        THROW 50050, @M, 1;
    END;

    -- bind parsed values to the declared parameter list: keywords by name,
    -- bare values by position, then defaults for anything still unset
    DECLARE @P TABLE (PARMSEQ INT, KWD VARCHAR(10), VAL VARCHAR(256));

    INSERT @P (PARMSEQ, KWD, VAL)
    SELECT CP.PARMSEQ, CP.KWD,
           COALESCE(BYNAME.VAL, BYPOS.VAL, CP.DFT)
    FROM   QSYS.COMMAND_PARM AS CP
    LEFT JOIN QSYS.CL_PARSE(@CMD) AS BYNAME
           ON BYNAME.KWD = CP.KWD
    LEFT JOIN (SELECT VAL, POSN = ROW_NUMBER() OVER (ORDER BY SEQ)
               FROM   QSYS.CL_PARSE(@CMD) WHERE KWD = '') AS BYPOS
           ON BYPOS.POSN = CP.PARMSEQ
    WHERE  CP.OBJID = @OBJID;

    IF EXISTS (SELECT 1 FROM QSYS.COMMAND_PARM AS CP
               JOIN @P AS P ON P.PARMSEQ = CP.PARMSEQ
               WHERE CP.OBJID = @OBJID AND CP.REQUIRED = 1 AND P.VAL IS NULL)
        THROW 50051, N'CPF0001 - Required parameter missing.', 1;

    DECLARE @SQL NVARCHAR(MAX) = N'EXEC ' + @PROC + N' ' +
    (
        SELECT STRING_AGG(CAST(N'@' + P.KWD + N' = ' +
                               CASE WHEN P.VAL IS NULL THEN N'DEFAULT'
                                    ELSE N'''' + REPLACE(P.VAL, N'''', N'''''') + N'''' END
                          AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY P.PARMSEQ)
        FROM @P AS P
    );

    EXEC sp_executesql @SQL;
END;
GO
