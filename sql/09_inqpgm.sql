/*===========================================================================
  AS/400 in SQL Server 2025  —  09: INQ100 as an interactive program
  ---------------------------------------------------------------------------
  One procedure, called once per AID key. It reads the job state, works out
  what the user did, rebuilds the subfile, and writes the screen.

      Enter          re-read from the Position-to field
      Page Down      roll up   — SETGT the last key on the page, read forward
      Page Up        roll down — SETLL the first key on the page, READP back
      5 + Enter      drill into that part's movements
      F12            back out of the movements screen
      F3             end the job

  Paging is not OFFSET/FETCH. It is SETGT/SETLL against the access path and
  then read until the page is full, which is why paging through a million
  records costs the same as paging through ten.
===========================================================================*/

CREATE OR ALTER PROCEDURE WARELIB.WSPGM
    @JOBID INT,
    @AID   VARCHAR(10) = 'ENTER',
    @INPUT QSYS.FIELD_VALUES READONLY
AS
BEGIN
    SET NOCOUNT ON;

    EXEC QSYS.SET_AID @JOBID, @AID;

    DECLARE @PGM VARCHAR(10), @STK VARCHAR(10),
            @TOP VARCHAR(256), @END VARCHAR(256),
            @CTX VARCHAR(256), @PAGENO INT;

    SELECT @PGM = CURPGM, @STK = PGMSTK, @TOP = PAGETOP, @END = PAGEEND,
           @CTX = CTXKEY, @PAGENO = PAGENO
    FROM   QSYS.WSJOB WHERE JOBID = @JOBID;

    ------------------------------------------------------------------ F3
    IF QSYS.IND(@JOBID, '03') = 1
    BEGIN
        UPDATE QSYS.WSJOB SET ENDED = 1 WHERE JOBID = @JOBID;
        RETURN;
    END;

    /*=====================================================================
      MOV100 — the movements screen. Only two things happen here.
    =====================================================================*/
    IF @PGM = 'MOV100'
    BEGIN
        IF QSYS.IND(@JOBID, '12') = 1
        BEGIN
            -- F12 pops back to the enquiry, on the page we left it on
            UPDATE QSYS.WSJOB
               SET CURPGM = ISNULL(@STK, 'INQ100'), PGMSTK = NULL,
                   MSGTXT = ''
             WHERE JOBID = @JOBID;
            SET @PGM = ISNULL(@STK, 'INQ100');
        END
        ELSE
        BEGIN
            EXEC WARELIB.SHOW_MOV @JOBID, @CTX;
            RETURN;
        END;
    END;

    /*=====================================================================
      INQ100 — the enquiry.
    =====================================================================*/

    ------------------------------------------- did they select a subfile line?
    DECLARE @SELRRN INT, @SELPART VARCHAR(256);

    SELECT TOP (1) @SELRRN = V.RRN
    FROM   @INPUT AS V
    WHERE  V.FLDNAME = 'SELOPT' AND V.RRN > 0
      AND  LTRIM(RTRIM(ISNULL(V.VAL, ''))) = '5'
    ORDER BY V.RRN;

    IF @SELRRN IS NOT NULL
    BEGIN
        -- the subfile is a real thing with real contents; ask it
        SELECT @SELPART = VAL
        FROM   QSYS.SFL_DATA
        WHERE  JOBID = @JOBID AND SFLRRN = @SELRRN AND FLDNAME = 'PARTNO';

        IF @SELPART IS NOT NULL
        BEGIN
            UPDATE QSYS.WSJOB
               SET CURPGM = 'MOV100', PGMSTK = 'INQ100',
                   CTXKEY = @SELPART, MSGTXT = ''
             WHERE JOBID = @JOBID;

            EXEC WARELIB.SHOW_MOV @JOBID, @SELPART;
            RETURN;
        END;
    END;

    ----------------------------------------------------- position / roll / page
    DECLARE @POSTO VARCHAR(256) =
        LTRIM(RTRIM(ISNULL((SELECT VAL FROM @INPUT
                            WHERE RRN = 0 AND FLDNAME = 'POSTO'), '')));

    DECLARE @MSG VARCHAR(76) = '';

    IF @POSTO <> ''
    BEGIN
        EXEC QSYS.SFL_PAGE @JOBID, 'WARELIB/PARTMST', 'PARTNO',
             @ANCHOR = @POSTO, @ROWS = 10;
        UPDATE QSYS.WSJOB SET PAGENO = 1 WHERE JOBID = @JOBID;
        SET @MSG = 'Positioned at ' + @POSTO + '.';
    END
    ELSE IF UPPER(@AID) = 'ROLLUP'
    BEGIN
        -- forward a page: SETGT the last key we showed
        DECLARE @PROBE INT = 0;
        EXEC QSYS.SFL_PAGE @JOBID, 'WARELIB/PARTMST', 'PARTNO',
             @ANCHOR = @END, @ROWS = 10, @GT = 1;

        IF NOT EXISTS (SELECT 1 FROM QSYS.SFL_DATA WHERE JOBID = @JOBID)
        BEGIN
            -- nothing past the end; put the page back and say so
            EXEC QSYS.SFL_PAGE @JOBID, 'WARELIB/PARTMST', 'PARTNO',
                 @ANCHOR = @TOP, @ROWS = 10;
            SET @MSG = 'Already at the bottom of the file.';
        END
        ELSE
        BEGIN
            UPDATE QSYS.WSJOB SET PAGENO = @PAGENO + 1 WHERE JOBID = @JOBID;
            SET @MSG = 'Page ' + CAST(@PAGENO + 1 AS VARCHAR(5)) + '.';
        END;
    END
    ELSE IF UPPER(@AID) = 'ROLLDOWN'
    BEGIN
        IF @PAGENO <= 1
            SET @MSG = 'Already at the top of the file.';
        ELSE
        BEGIN
            EXEC QSYS.SFL_PAGE @JOBID, 'WARELIB/PARTMST', 'PARTNO',
                 @ANCHOR = @TOP, @ROWS = 10, @BACKWARD = 1;
            UPDATE QSYS.WSJOB SET PAGENO = @PAGENO - 1 WHERE JOBID = @JOBID;
            SET @MSG = 'Page ' + CAST(@PAGENO - 1 AS VARCHAR(5)) + '.';
        END;
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM QSYS.SFL_DATA WHERE JOBID = @JOBID)
    BEGIN
        -- first time in
        EXEC QSYS.SFL_PAGE @JOBID, 'WARELIB/PARTMST', 'PARTNO', @ROWS = 10;
        SET @MSG = 'Type 5 against a part to see its movements.';
    END;

    IF @SELRRN IS NOT NULL AND @SELPART IS NULL
        SET @MSG = 'No part on that line.';

    EXEC WARELIB.SHOW_INQ @JOBID, @MSG;
END;
GO

/*---------------------------------------------------------------------------
  Write the enquiry screen from the subfile.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.SHOW_INQ
    @JOBID INT,
    @MSG   VARCHAR(76) = ''
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @V QSYS.FIELD_VALUES, @N INT;
    SELECT @N = ISNULL(MAX(SFLRRN), 0) FROM QSYS.SFL_DATA WHERE JOBID = @JOBID;

    INSERT @V (RRN, FLDNAME, VAL)
    SELECT SFLRRN, FLDNAME, VAL
    FROM   QSYS.SFL_DATA
    WHERE  JOBID = @JOBID
      AND  FLDNAME IN ('PARTNO','DESCR','BINLOC','QTYOH','SYSQTY');

    INSERT @V (RRN, FLDNAME, VAL)
    SELECT SFLRRN, 'SELOPT', ''
    FROM  (SELECT DISTINCT SFLRRN FROM QSYS.SFL_DATA WHERE JOBID = @JOBID) AS S;

    INSERT @V (RRN, FLDNAME, VAL) VALUES
        (0, 'LIBNAM', 'WARELIB'),
        (0, 'WHSE',   'WATFORD'),
        (0, 'POSTO',  ''),
        (0, 'MSGTXT', @MSG);

    UPDATE QSYS.WSJOB SET MSGTXT = @MSG WHERE JOBID = @JOBID;

    EXEC QSYS.EXFMT 'WARELIB', 'INQ100', 'INQCTL', @V, @SFLROWS = @N;
END;
GO

/*---------------------------------------------------------------------------
  Write the movements screen: CHAIN for the header, READE for the lines.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.SHOW_MOV
    @JOBID  INT,
    @PARTNO VARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @P INT, @M INT, @V QSYS.FIELD_VALUES, @N INT = 0;

    EXEC QSYS.OPNDBF 'WARELIB/PARTMST', NULL, @P OUTPUT;
    EXEC QSYS.CHAIN @P, @PARTNO;

    IF QSYS.PCT_FOUND(@P) = 1
        INSERT @V (RRN, FLDNAME, VAL)
        SELECT 0, FLDNAME, VAL FROM QSYS.BUF(@P)
        WHERE  FLDNAME IN ('PARTNO','DESCR','QTYOH','SYSQTY');

    EXEC QSYS.OPNDBF 'WARELIB/STKMOV', NULL, @M OUTPUT;
    EXEC QSYS.SETLL @M, @PARTNO;

    WHILE @N < 10
    BEGIN
        EXEC QSYS.READ_REC @M, @PRIOR = 0, @K1 = @PARTNO;   -- READE
        IF QSYS.PCT_EOF(@M) = 1 BREAK;
        SET @N = @N + 1;
        INSERT @V (RRN, FLDNAME, VAL)
        SELECT @N, FLDNAME, VAL FROM QSYS.BUF(@M)
        WHERE  FLDNAME IN ('MOVSEQ','MOVDAT','MOVTYP','MOVQTY','MOVREF');
    END;

    INSERT @V (RRN, FLDNAME, VAL) VALUES
        (0, 'LIBNAM', 'WARELIB'),
        (0, 'MSGTXT', CAST(@N AS VARCHAR(5)) +
                      ' movements read with READE.  F12=Back');

    EXEC QSYS.CLOF @P;
    EXEC QSYS.CLOF @M;

    EXEC QSYS.EXFMT 'WARELIB', 'MOV100', 'MOVCTL', @V, @SFLROWS = @N;
END;
GO

/*---------------------------------------------------------------------------
  Sign on: start a job and write the first screen.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.SIGNON
    @JOBID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.STRWSJOB 'INQ100', @JOBID OUTPUT;

    DECLARE @EMPTY QSYS.FIELD_VALUES;
    EXEC WARELIB.WSPGM @JOBID, 'ENTER', @EMPTY;
END;
GO

/*---------------------------------------------------------------------------
  A string-parameter wrapper for the program.

  Table-valued parameters work, but driver support for them is uneven and a
  terminal client should not need a particular ODBC version to type into a
  field. The input arrives as  rrn US name US value RS ...  which every
  driver can pass as a plain string.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.WSPGM_STR
    @JOBID INT,
    @AID   VARCHAR(10) = 'ENTER',
    @INPUT VARCHAR(MAX) = ''
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @V QSYS.FIELD_VALUES;

    -- record separator CHAR(30), field separator CHAR(31)
    INSERT @V (RRN, FLDNAME, VAL)
    SELECT TRY_CAST(A.RRNS AS INT), LEFT(B.NM, 10), B.VL
    FROM   STRING_SPLIT(ISNULL(@INPUT, ''), CHAR(30)) AS REC
    CROSS APPLY (SELECT
        RRNS = LEFT(REC.value, CHARINDEX(CHAR(31), REC.value + CHAR(31)) - 1),
        REST = SUBSTRING(REC.value, CHARINDEX(CHAR(31), REC.value + CHAR(31)) + 1, 8000)
    ) AS A
    CROSS APPLY (SELECT
        NM = LEFT(A.REST, CHARINDEX(CHAR(31), A.REST + CHAR(31)) - 1),
        VL = SUBSTRING(A.REST, CHARINDEX(CHAR(31), A.REST + CHAR(31)) + 1, 8000)
    ) AS B
    WHERE  REC.value <> '' AND TRY_CAST(A.RRNS AS INT) IS NOT NULL;

    EXEC WARELIB.WSPGM @JOBID, @AID, @V;
END;
GO

/*---------------------------------------------------------------------------
  Has the job ended? The terminal asks after every turn.
---------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION WARELIB.JOB_ENDED (@JOBID INT)
RETURNS BIT
AS
BEGIN
    RETURN ISNULL((SELECT ENDED FROM QSYS.WSJOB WHERE JOBID = @JOBID), 1);
END;
GO
