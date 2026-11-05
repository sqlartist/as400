/*===========================================================================
  AS/400 in SQL Server 2025  —  03: the 5250 character-grid renderer
  ---------------------------------------------------------------------------
  A 5250 screen is not a drawing. It is a projection: take a record format,
  take a row of data, and produce a 24 x 80 grid of characters. Every field
  already carries its own line and position from the DDS, so this is a join
  and an aggregate, not a paint loop.

  How it works:
      1. turn every field into one WRITE   (line, position, text, attribute)
      2. explode each write into characters (line, position, char)
      3. later writes win where they overlap
      4. left join onto the full 24 x 80 grid and STRING_AGG each line

  On a real 5250 each field is preceded by an attribute byte that occupies a
  screen position. We keep attributes in a parallel plane instead, so text
  lands exactly where the DDS says it should. That is a deliberate trade:
  fidelity of layout over fidelity of the wire protocol.
===========================================================================*/

-- Re-runnable: this script is the one you will re-run most while building.
IF OBJECT_ID(N'QSYS.TALLY', N'U') IS NULL
    CREATE TABLE QSYS.TALLY (N INT NOT NULL PRIMARY KEY CLUSTERED);
GO
IF NOT EXISTS (SELECT 1 FROM QSYS.TALLY)
    INSERT QSYS.TALLY (N)
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM   sys.all_objects AS A CROSS JOIN sys.all_objects AS B;
GO

/*---------------------------------------------------------------------------
  Field values to bind into a format.
    RRN = 0   the record itself
    RRN > 0   a subfile record, one per displayed line

  Not dropped and recreated: once a procedure references a table type, the
  type cannot be dropped, and this script has to stay re-runnable.
---------------------------------------------------------------------------*/
IF TYPE_ID(N'QSYS.FIELD_VALUES') IS NULL
EXEC (N'
CREATE TYPE QSYS.FIELD_VALUES AS TABLE
(
    RRN     INT           NOT NULL DEFAULT 0,
    FLDNAME VARCHAR(10)   NOT NULL,
    VAL     VARCHAR(256)  NULL,
    PRIMARY KEY CLUSTERED (RRN, FLDNAME)
);');
GO

/*---------------------------------------------------------------------------
  Format one value into its field width.

  A numeric output field with no edit code shows its leading zeros. That is
  not a bug — it is what the machine does, and it is why every DDS author
  eventually learns EDTCDE. We keep the behaviour.

      EDTCDE 1..4 / J / Z  suppress leading zeros
      EDTCDE 1,2,3,4       also insert thousands separators
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION QSYS.FMT_FIELD
(
    @VAL    VARCHAR(256),
    @DTYPE  CHAR(1),
    @LEN    SMALLINT,
    @DEC    SMALLINT,
    @EDTCDE VARCHAR(10)
)
RETURNS VARCHAR(256)
AS
BEGIN
    IF @LEN <= 0 RETURN '';

    DECLARE @OUT VARCHAR(256);
    SET @EDTCDE = UPPER(LTRIM(RTRIM(ISNULL(@EDTCDE, ''))));

    IF UPPER(@DTYPE) IN ('P','S','B')
    BEGIN
        DECLARE @D SMALLINT = ISNULL(@DEC, 0);
        DECLARE @N DECIMAL(31,9) = ISNULL(TRY_CAST(@VAL AS DECIMAL(31,9)), 0);
        DECLARE @NEG BIT = CASE WHEN @N < 0 THEN 1 ELSE 0 END;

        -- digits, no sign, no point: the stored representation
        DECLARE @DIGITS VARCHAR(64) =
            REPLACE(CAST(CAST(ABS(@N) * POWER(CAST(10 AS DECIMAL(31,9)), @D)
                              AS DECIMAL(31,0)) AS VARCHAR(64)), '-', '');

        SET @DIGITS = RIGHT(REPLICATE('0', @LEN) + @DIGITS, @LEN);

        IF @D > 0
            SET @OUT = LEFT(@DIGITS, @LEN - @D) + '.' + RIGHT(@DIGITS, @D);
        ELSE
            SET @OUT = @DIGITS;

        IF @EDTCDE IN ('1','2','3','4','J','Z')
        BEGIN
            -- zero suppression
            DECLARE @INT VARCHAR(64) =
                CASE WHEN @D > 0 THEN LEFT(@OUT, LEN(@OUT) - @D - 1) ELSE @OUT END;
            DECLARE @FRC VARCHAR(64) =
                CASE WHEN @D > 0 THEN RIGHT(@OUT, @D + 1) ELSE '' END;

            WHILE LEN(@INT) > 1 AND LEFT(@INT, 1) = '0'
                SET @INT = SUBSTRING(@INT, 2, LEN(@INT));

            IF @INT = '0' AND @EDTCDE IN ('2','4') SET @INT = '';

            IF @EDTCDE IN ('1','2','3','4') AND LEN(@INT) > 3
            BEGIN
                DECLARE @G VARCHAR(64) = '', @I INT = LEN(@INT);
                WHILE @I > 0
                BEGIN
                    SET @G = SUBSTRING(@INT, CASE WHEN @I - 2 < 1 THEN 1 ELSE @I - 2 END,
                                       CASE WHEN @I - 2 < 1 THEN @I ELSE 3 END)
                             + CASE WHEN @G = '' THEN '' ELSE ',' + @G END;
                    SET @I = @I - 3;
                END;
                SET @INT = @G;
            END;

            SET @OUT = @INT + @FRC;
        END;

        IF @NEG = 1 SET @OUT = '-' + @OUT;

        -- numerics are right justified in their field
        IF LEN(@OUT) > @LEN SET @OUT = RIGHT(@OUT, @LEN);
        RETURN RIGHT(REPLICATE(' ', @LEN) + @OUT, @LEN);
    END;

    -- character: left justified, blank padded
    SET @OUT = ISNULL(@VAL, '');
    IF LEN(@OUT) > @LEN SET @OUT = LEFT(@OUT, @LEN);
    RETURN LEFT(@OUT + REPLICATE(' ', @LEN), @LEN);
END;
GO

/*===========================================================================
  RENDER — build the grid.

  Returns one row per screen line: LIN, LINETEXT, plus the attribute plane
  as a second column so a front end can colour it without re-deriving
  anything.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.RENDER
    @LIBNAME  VARCHAR(10),
    @FILENAME VARCHAR(10),
    @FMTNAME  VARCHAR(10),
    @VALUES   QSYS.FIELD_VALUES READONLY,
    @TRIM     BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OBJID INT, @ROWS SMALLINT, @COLS SMALLINT;

    SELECT @OBJID = F.OBJID, @ROWS = ISNULL(F.DSPSIZ_ROWS, 24), @COLS = ISNULL(F.DSPSIZ_COLS, 80)
    FROM   QSYS.OBJECT AS O
    JOIN   QSYS.[FILE] AS F ON F.OBJID = O.OBJID
    WHERE  O.LIBNAME = UPPER(@LIBNAME)
      AND  O.OBJNAME = UPPER(@FILENAME)
      AND  O.OBJTYPE = '*FILE';

    IF @OBJID IS NULL
        THROW 50030, N'CPF4101 - Display file not found.', 1;

    ------------------------------------------------------------------------
    -- Which formats are we drawing? A control format drags its subfile in
    -- with it, exactly as WRITE/EXFMT does on the machine.
    ------------------------------------------------------------------------
    DROP TABLE IF EXISTS #FMTS;
    SELECT R.FMTID, R.FMTNAME, R.FMTKIND, R.SFLPAG,
           DRAWSEQ = CASE WHEN R.FMTKIND = 'SFL' THEN 2 ELSE 1 END
    INTO   #FMTS
    FROM   QSYS.RECORD_FORMAT AS R
    WHERE  R.OBJID = @OBJID
      AND  ( R.FMTNAME = UPPER(@FMTNAME)
             OR R.FMTNAME = (SELECT C.SFL_FMT
                             FROM   QSYS.RECORD_FORMAT AS C
                             WHERE  C.OBJID = @OBJID AND C.FMTNAME = UPPER(@FMTNAME)) );

    IF NOT EXISTS (SELECT 1 FROM #FMTS)
        THROW 50031, N'CPF5070 - Record format not found in display file.', 1;

    DECLARE @SFLPAG SMALLINT =
        ISNULL((SELECT MAX(SFLPAG) FROM #FMTS WHERE FMTKIND = 'SFLCTL'), 0);

    ------------------------------------------------------------------------
    -- 1. every field becomes one write
    --    Control and plain formats are drawn first, then the subfile lines
    --    on top of them, which is the order EXFMT effectively applies.
    ------------------------------------------------------------------------
    DROP TABLE IF EXISTS #WRITES;
    CREATE TABLE #WRITES
    (
        WRITESEQ INT IDENTITY(1,1) NOT NULL,
        LIN      SMALLINT     NOT NULL,
        POS      SMALLINT     NOT NULL,
        TXT      VARCHAR(256) NOT NULL,
        ATTR     VARCHAR(30)  NOT NULL
    );

    -- plain and control formats: a single pass, values bound at RRN 0
    INSERT #WRITES (LIN, POS, TXT, ATTR)
    SELECT D.LIN,
           D.POS,
           CASE WHEN D.FLDKIND = 'C' THEN ISNULL(D.CONSTANT, '')
                ELSE QSYS.FMT_FIELD(V.VAL, D.DTYPE, D.FLDLEN, D.DECPOS, D.EDTCDE)
           END,
           D.DSPATR
    FROM   #FMTS AS F
    JOIN   QSYS.DSPF_FIELD AS D ON D.FMTID = F.FMTID
    LEFT JOIN @VALUES AS V ON V.FLDNAME = D.FLDNAME AND V.RRN = 0
    WHERE  F.FMTKIND <> 'SFL'
      AND  (D.FLDKIND = 'C' OR D.USAGE IN ('O','B'))
    ORDER BY F.FMTID, D.FLDSEQ;

    -- subfile: one pass per record, each sitting one line further down,
    -- and never more of them than SFLPAG says fit on the page
    INSERT #WRITES (LIN, POS, TXT, ATTR)
    SELECT D.LIN + (S.RRN - 1),
           D.POS,
           CASE WHEN D.FLDKIND = 'C' THEN ISNULL(D.CONSTANT, '')
                ELSE QSYS.FMT_FIELD(V.VAL, D.DTYPE, D.FLDLEN, D.DECPOS, D.EDTCDE)
           END,
           D.DSPATR
    FROM   #FMTS AS F
    JOIN   QSYS.DSPF_FIELD AS D ON D.FMTID = F.FMTID
    CROSS JOIN (SELECT DISTINCT RRN FROM @VALUES WHERE RRN > 0) AS S
    LEFT JOIN @VALUES AS V ON V.FLDNAME = D.FLDNAME AND V.RRN = S.RRN
    WHERE  F.FMTKIND = 'SFL'
      AND  (D.FLDKIND = 'C' OR D.USAGE IN ('O','B'))
      AND  (@SFLPAG = 0 OR S.RRN <= @SFLPAG)
    ORDER BY S.RRN, D.FLDSEQ;

    -- clip to the screen. DATALENGTH, not LEN: a field rendered as all
    -- blanks is still a write, and LEN would report it as empty.
    DELETE FROM #WRITES
    WHERE  LIN < 1 OR LIN > @ROWS OR POS < 1 OR POS > @COLS OR DATALENGTH(TXT) = 0;

    ------------------------------------------------------------------------
    -- 2. explode writes into characters, 3. later writes win
    ------------------------------------------------------------------------
    DROP TABLE IF EXISTS #CHARS;

    SELECT LIN, POS, CH, ATTR
    INTO   #CHARS
    FROM
    (
        SELECT W.LIN,
               POS = W.POS + T.N - 1,
               CH  = SUBSTRING(W.TXT, T.N, 1),
               W.ATTR,
               RN  = ROW_NUMBER() OVER (
                         PARTITION BY W.LIN, W.POS + T.N - 1
                         ORDER BY W.WRITESEQ DESC)
        FROM   #WRITES AS W
        JOIN   QSYS.TALLY AS T ON T.N <= LEN(W.TXT)
        WHERE  W.POS + T.N - 1 <= @COLS
    ) AS X
    WHERE  RN = 1;

    ------------------------------------------------------------------------
    -- 4. left join onto the full grid and reassemble
    ------------------------------------------------------------------------
    SELECT   LIN      = L.N,
             LINETEXT = CASE WHEN @TRIM = 1
                             THEN RTRIM(STRING_AGG(ISNULL(C.CH, ' '), '')
                                        WITHIN GROUP (ORDER BY P.N))
                             ELSE STRING_AGG(ISNULL(C.CH, ' '), '')
                                        WITHIN GROUP (ORDER BY P.N)
                        END,
             ATTRTEXT = STRING_AGG(
                            CASE WHEN C.ATTR LIKE '%HI%' THEN 'H'
                                 WHEN C.ATTR LIKE '%RI%' THEN 'R'
                                 WHEN C.ATTR LIKE '%UL%' THEN 'U'
                                 WHEN C.ATTR LIKE '%ND%' THEN 'N'
                                 WHEN C.CH IS NULL THEN ' '
                                 ELSE '.' END, '')
                        WITHIN GROUP (ORDER BY P.N)
    FROM     QSYS.TALLY AS L
    CROSS JOIN QSYS.TALLY AS P
    LEFT JOIN #CHARS AS C ON C.LIN = L.N AND C.POS = P.N
    WHERE    L.N <= @ROWS AND P.N <= @COLS
    GROUP BY L.N
    ORDER BY L.N;
END;
GO

/*---------------------------------------------------------------------------
  SHOW — render and print it, framed, so you can look at the thing.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.SHOW
    @LIBNAME  VARCHAR(10),
    @FILENAME VARCHAR(10),
    @FMTNAME  VARCHAR(10),
    @VALUES   QSYS.FIELD_VALUES READONLY
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #SCR;
    CREATE TABLE #SCR (LIN INT, LINETEXT VARCHAR(200), ATTRTEXT VARCHAR(200));

    INSERT #SCR EXEC QSYS.RENDER @LIBNAME, @FILENAME, @FMTNAME, @VALUES, 0;

    -- DATALENGTH, not LEN: every line is padded to the full screen width and
    -- LEN would ignore the trailing blanks, giving a frame too narrow to fit.
    DECLARE @COLS INT = (SELECT MAX(DATALENGTH(LINETEXT)) FROM #SCR);
    PRINT '+' + REPLICATE('-', @COLS) + '+';

    DECLARE @I INT = 1, @MAX INT = (SELECT MAX(LIN) FROM #SCR), @L VARCHAR(200);
    WHILE @I <= @MAX
    BEGIN
        SELECT @L = LINETEXT FROM #SCR WHERE LIN = @I;
        PRINT '|' + LEFT(@L + REPLICATE(' ', @COLS), @COLS) + '|';
        SET @I = @I + 1;
    END;

    PRINT '+' + REPLICATE('-', @COLS) + '+';
END;
GO
