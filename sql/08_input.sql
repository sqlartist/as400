/*===========================================================================
  AS/400 in SQL Server 2025  —  08: screen input
  ---------------------------------------------------------------------------
  A 5250 is a BLOCK MODE terminal, and that single fact decides the whole
  design of this layer.

  The host sends a screen. The terminal displays it and the user types into
  it entirely on their own — the host sees nothing, because nothing is being
  transmitted. Only when an AID key is pressed (Enter, a function key, a
  roll key) does the terminal send the whole input buffer back in one go.

  So a program is not a loop that waits for input. It is a state machine
  that gets called once per keystroke-that-matters, which is exactly what a
  stored procedure can be. Nothing has to block.

      EXFMT  =  render a screen, hand back the grid and the input map
      then the terminal goes away and comes back with an AID key and values
      the program picks up where it left off

  Which also means this layer is honest about something the set-based demos
  were not: the interaction really is turn by turn.
===========================================================================*/

DROP TABLE IF EXISTS QSYS.SFL_DATA;
DROP TABLE IF EXISTS QSYS.INDICATOR;
DROP TABLE IF EXISTS QSYS.WSJOB;
GO

/*---------------------------------------------------------------------------
  A workstation job. One row per person sat at a terminal.

  PGMSTK is a one-deep program stack: the screen you drilled down FROM, so
  F12 can put you back. A real machine has an invocation stack; this is
  enough for two screens and says so.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.WSJOB
(
    JOBID    INT IDENTITY(1,1) NOT NULL,
    USERNAME VARCHAR(10)   NOT NULL DEFAULT 'TREVOR',
    CURPGM   VARCHAR(10)   NOT NULL,
    PGMSTK   VARCHAR(10)   NULL,
    -- subfile paging: the key the current page starts at, and the one it ends at
    PAGETOP  VARCHAR(256)  NULL,
    PAGEEND  VARCHAR(256)  NULL,
    PAGENO   INT           NOT NULL DEFAULT 1,
    -- whatever the current program needs to remember between turns
    CTXKEY   VARCHAR(256)  NULL,
    MSGTXT   VARCHAR(76)   NOT NULL DEFAULT '',
    ENDED    BIT           NOT NULL DEFAULT 0,
    CONSTRAINT PK_WSJOB PRIMARY KEY CLUSTERED (JOBID)
);
GO

/*---------------------------------------------------------------------------
  *IN01 .. *IN99. Function keys set them, the program reads them, and that
  is genuinely how the machine worked.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.INDICATOR
(
    JOBID INT          NOT NULL,
    IND   CHAR(2)      NOT NULL,
    VAL   BIT          NOT NULL DEFAULT 0,
    CONSTRAINT PK_INDICATOR PRIMARY KEY CLUSTERED (JOBID, IND),
    CONSTRAINT FK_IND_JOB FOREIGN KEY (JOBID)
        REFERENCES QSYS.WSJOB (JOBID) ON DELETE CASCADE
);
GO

/*---------------------------------------------------------------------------
  AID keys. The terminal sends one of these with the input buffer; the
  numbered ones set the matching indicator.
---------------------------------------------------------------------------*/
/*---------------------------------------------------------------------------
  The subfile itself. On the machine, records are WRITTEN into a subfile and
  then the whole thing is displayed — the subfile is a real object with real
  contents, not a query result that happens to be on screen. This is it.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.SFL_DATA
(
    JOBID   INT          NOT NULL,
    SFLRRN  INT          NOT NULL,
    FLDNAME VARCHAR(10)  NOT NULL,
    VAL     VARCHAR(256) NULL,
    CONSTRAINT PK_SFL_DATA PRIMARY KEY CLUSTERED (JOBID, SFLRRN, FLDNAME),
    CONSTRAINT FK_SFL_JOB FOREIGN KEY (JOBID)
        REFERENCES QSYS.WSJOB (JOBID) ON DELETE CASCADE
);
GO

CREATE OR ALTER FUNCTION QSYS.AID_IND (@AID VARCHAR(10))
RETURNS CHAR(2)
AS
BEGIN
    RETURN CASE UPPER(LTRIM(RTRIM(@AID)))
        WHEN 'F1'  THEN '01' WHEN 'F2'  THEN '02' WHEN 'F3'  THEN '03'
        WHEN 'F4'  THEN '04' WHEN 'F5'  THEN '05' WHEN 'F6'  THEN '06'
        WHEN 'F7'  THEN '07' WHEN 'F8'  THEN '08' WHEN 'F9'  THEN '09'
        WHEN 'F10' THEN '10' WHEN 'F11' THEN '11' WHEN 'F12' THEN '12'
        ELSE NULL
    END;
END;
GO

/*===========================================================================
  The input map — which parts of the screen the user may type into.

  This is read straight out of the DDS: usage I or B, from position 38.
  The terminal needs it to know where to let the cursor go, and how far the
  field runs. Subfile fields are expanded one row per displayed record,
  the same way the renderer expands them.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.INPUT_MAP
    @LIBNAME  VARCHAR(10),
    @FILENAME VARCHAR(10),
    @FMTNAME  VARCHAR(10),
    @SFLROWS  INT = 0            -- how many subfile records are on the page
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OBJID INT;
    SELECT @OBJID = O.OBJID
    FROM   QSYS.OBJECT AS O
    WHERE  O.LIBNAME = UPPER(@LIBNAME) AND O.OBJNAME = UPPER(@FILENAME)
      AND  O.OBJTYPE = '*FILE';

    DROP TABLE IF EXISTS #F;
    SELECT R.FMTID, R.FMTNAME, R.FMTKIND
    INTO   #F
    FROM   QSYS.RECORD_FORMAT AS R
    WHERE  R.OBJID = @OBJID
      AND  ( R.FMTNAME = UPPER(@FMTNAME)
             OR R.FMTNAME = (SELECT C.SFL_FMT FROM QSYS.RECORD_FORMAT AS C
                             WHERE C.OBJID = @OBJID AND C.FMTNAME = UPPER(@FMTNAME)) );

    -- fields on the control/plain formats: one entry each
    SELECT  SFLRRN  = 0,
            FLDNAME = D.FLDNAME,
            LIN     = D.LIN,
            POS     = D.POS,
            FLDLEN  = D.FLDLEN,
            DTYPE   = D.DTYPE,
            SEQ     = ROW_NUMBER() OVER (ORDER BY D.LIN, D.POS)
    INTO    #MAP
    FROM    #F AS F
    JOIN    QSYS.DSPF_FIELD AS D ON D.FMTID = F.FMTID
    WHERE   F.FMTKIND <> 'SFL' AND D.FLDKIND = 'F' AND D.USAGE IN ('I','B');

    -- subfile fields: one entry per displayed record, one line further down
    INSERT #MAP (SFLRRN, FLDNAME, LIN, POS, FLDLEN, DTYPE, SEQ)
    SELECT  S.N, D.FLDNAME, D.LIN + S.N - 1, D.POS, D.FLDLEN, D.DTYPE,
            1000 + ROW_NUMBER() OVER (ORDER BY S.N, D.POS)
    FROM    #F AS F
    JOIN    QSYS.DSPF_FIELD AS D ON D.FMTID = F.FMTID
    CROSS JOIN QSYS.TALLY AS S
    WHERE   F.FMTKIND = 'SFL' AND D.FLDKIND = 'F' AND D.USAGE IN ('I','B')
      AND   S.N <= @SFLROWS;

    SELECT SFLRRN, FLDNAME, LIN, POS, FLDLEN, DTYPE
    FROM   #MAP
    ORDER BY LIN, POS;
END;
GO

/*===========================================================================
  EXFMT — write the screen and hand back everything the terminal needs.

  Two result sets: the 24 rendered lines with their attribute plane, then
  the input map. The terminal draws the first and uses the second to decide
  where the user is allowed to type.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.EXFMT
    @LIBNAME  VARCHAR(10),
    @FILENAME VARCHAR(10),
    @FMTNAME  VARCHAR(10),
    @VALUES   QSYS.FIELD_VALUES READONLY,
    @SFLROWS  INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC QSYS.RENDER @LIBNAME, @FILENAME, @FMTNAME, @VALUES, 0;
    EXEC QSYS.INPUT_MAP @LIBNAME, @FILENAME, @FMTNAME, @SFLROWS;
END;
GO

/*===========================================================================
  Starting and ending a workstation job.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.STRWSJOB
    @PGM   VARCHAR(10),
    @JOBID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT QSYS.WSJOB (CURPGM) VALUES (UPPER(@PGM));
    SET @JOBID = SCOPE_IDENTITY();

    INSERT QSYS.INDICATOR (JOBID, IND, VAL)
    SELECT @JOBID, RIGHT('0' + CAST(N AS VARCHAR(2)), 2), 0
    FROM   QSYS.TALLY WHERE N BETWEEN 1 AND 99;
END;
GO

CREATE OR ALTER PROCEDURE QSYS.ENDWSJOB @JOBID INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE QSYS.WSJOB WHERE JOBID = @JOBID;      -- indicators cascade
END;
GO

/*---------------------------------------------------------------------------
  Set the indicators for an incoming AID key. Everything is cleared first,
  because indicators are per-interaction, not sticky.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.SET_AID @JOBID INT, @AID VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE QSYS.INDICATOR SET VAL = 0 WHERE JOBID = @JOBID;

    DECLARE @IND CHAR(2) = QSYS.AID_IND(@AID);
    IF @IND IS NOT NULL
        UPDATE QSYS.INDICATOR SET VAL = 1 WHERE JOBID = @JOBID AND IND = @IND;
END;
GO

CREATE OR ALTER FUNCTION QSYS.IND (@JOBID INT, @IND CHAR(2))
RETURNS BIT
AS
BEGIN
    RETURN ISNULL((SELECT VAL FROM QSYS.INDICATOR
                   WHERE JOBID = @JOBID AND IND = @IND), 0);
END;
GO

/*===========================================================================
  Subfile paging, off the access path.

  A page is not OFFSET/FETCH. It is SETLL to an anchor key and then READ
  until the page is full — which is how the machine did it, and why paging
  through a million-record file cost the same as paging through ten.
===========================================================================*/
CREATE OR ALTER PROCEDURE QSYS.SFL_PAGE
    @JOBID    INT,
    @FILE     VARCHAR(100),
    @KEYFLD   VARCHAR(10),           -- the field the page is anchored on
    @ANCHOR   VARCHAR(256) = NULL,   -- key to start at; NULL = *LOVAL
    @ROWS     INT = 10,
    @BACKWARD BIT = 0,               -- page backwards from the anchor
    @GT       BIT = 0                -- start AFTER the anchor, not at it
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @O INT;
    EXEC QSYS.OPNDBF @FILE, NULL, @O OUTPUT;

    DELETE QSYS.SFL_DATA WHERE JOBID = @JOBID;

    DECLARE @N INT = 0, @B INT = 0;

    IF @BACKWARD = 0
    BEGIN
        IF @ANCHOR IS NULL     EXEC QSYS.SETLL @O;
        ELSE IF @GT = 1        EXEC QSYS.SETGT @O, @ANCHOR;
        ELSE                   EXEC QSYS.SETLL @O, @ANCHOR;

        WHILE @N < @ROWS
        BEGIN
            EXEC QSYS.READ_REC @O;
            IF QSYS.PCT_EOF(@O) = 1 BREAK;
            SET @N = @N + 1;
            INSERT QSYS.SFL_DATA (JOBID, SFLRRN, FLDNAME, VAL)
            SELECT @JOBID, @N, FLDNAME, VAL FROM QSYS.BUF(@O);
        END;
    END
    ELSE
    BEGIN
        -- Paging back is READP. Walk backwards from the anchor collecting
        -- rows, then flip them the right way up.
        EXEC QSYS.SETLL @O, @ANCHOR;

        WHILE @B < @ROWS
        BEGIN
            EXEC QSYS.READ_REC @O, @PRIOR = 1;
            IF QSYS.PCT_EOF(@O) = 1 BREAK;
            SET @B = @B + 1;
            INSERT QSYS.SFL_DATA (JOBID, SFLRRN, FLDNAME, VAL)
            SELECT @JOBID, -@B, FLDNAME, VAL FROM QSYS.BUF(@O);
        END;

        UPDATE QSYS.SFL_DATA SET SFLRRN = @B + SFLRRN + 1
         WHERE JOBID = @JOBID;                    -- -1 becomes @B, -@B becomes 1
        SET @N = @B;
    END;

    UPDATE QSYS.WSJOB
       SET PAGENO  = CASE WHEN @ANCHOR IS NULL THEN 1 ELSE PAGENO END,
           PAGETOP = (SELECT VAL FROM QSYS.SFL_DATA
                      WHERE JOBID = @JOBID AND SFLRRN = 1 AND FLDNAME = @KEYFLD),
           PAGEEND = (SELECT VAL FROM QSYS.SFL_DATA
                      WHERE JOBID = @JOBID AND SFLRRN = @N AND FLDNAME = @KEYFLD)
     WHERE JOBID = @JOBID;

    EXEC QSYS.CLOF @O;
END;
GO
