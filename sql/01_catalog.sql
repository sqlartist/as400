/*===========================================================================
  AS/400 in SQL Server 2025  —  01: the QSYS object catalog
  ---------------------------------------------------------------------------
  On an AS/400 everything is an object in a library, and the library list
  decides which one you get. That is a catalog, so we build it as one.

    *LIB     a library                -> QSYS.LIBRARY
    *FILE    PF / LF / DSPF / PRTF    -> QSYS.OBJECT + QSYS.FILE
    *PGM     a program                -> QSYS.OBJECT (+ generated procedure)
    *CMD     a command                -> QSYS.OBJECT + QSYS.COMMAND
    *DTAARA  a data area              -> QSYS.OBJECT + QSYS.DTAARA

  Object names are 10 characters, uppercase, as they are on the machine.
===========================================================================*/

IF DB_NAME() = N'master'
    THROW 50000, N'Run this against your AS400 database, not master.', 1;
GO

IF SCHEMA_ID(N'QSYS') IS NULL EXEC (N'CREATE SCHEMA QSYS');
GO

/*---------------------------------------------------------------------------
  A machine-wide name type. 10 chars, and we store it uppercase.
---------------------------------------------------------------------------*/
IF TYPE_ID(N'QSYS.OBJNAME') IS NULL
    CREATE TYPE QSYS.OBJNAME FROM VARCHAR(10) NOT NULL;
GO

DROP TABLE IF EXISTS QSYS.FIELD;
DROP TABLE IF EXISTS QSYS.RECORD_FORMAT;
DROP TABLE IF EXISTS QSYS.FILE_MEMBER;
DROP TABLE IF EXISTS QSYS.DSPF_FIELD;
DROP TABLE IF EXISTS QSYS.COMMAND_PARM;
DROP TABLE IF EXISTS QSYS.COMMAND;
DROP TABLE IF EXISTS QSYS.DTAARA;
DROP TABLE IF EXISTS QSYS.SRC_MBR;
DROP TABLE IF EXISTS QSYS.[FILE];
DROP TABLE IF EXISTS QSYS.LIBL;
DROP TABLE IF EXISTS QSYS.JOB;
DROP TABLE IF EXISTS QSYS.OBJECT;
DROP TABLE IF EXISTS QSYS.LIBRARY;
GO

/*---------------------------------------------------------------------------
  *LIB
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.LIBRARY
(
    LIBNAME     QSYS.OBJNAME    NOT NULL,
    TEXT        VARCHAR(50)     NOT NULL DEFAULT '',
    LIBTYPE     VARCHAR(10)     NOT NULL DEFAULT '*PROD',   -- *PROD | *TEST
    CRTDATE     DATETIME2(0)    NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_LIBRARY PRIMARY KEY CLUSTERED (LIBNAME),
    CONSTRAINT CK_LIBRARY_UPPER CHECK (LIBNAME = UPPER(LIBNAME))
);
GO

/*---------------------------------------------------------------------------
  Every object on the machine. One row per object, exactly as WRKOBJ shows it.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.OBJECT
(
    OBJID       INT IDENTITY(1,1) NOT NULL,
    LIBNAME     QSYS.OBJNAME    NOT NULL,
    OBJNAME     QSYS.OBJNAME    NOT NULL,
    OBJTYPE     VARCHAR(10)     NOT NULL,   -- *FILE *PGM *CMD *DTAARA *LIB ...
    OBJATTR     VARCHAR(10)     NOT NULL DEFAULT '',  -- PF LF DSPF PRTF RPGLE CLP
    TEXT        VARCHAR(50)     NOT NULL DEFAULT '',
    OWNER       QSYS.OBJNAME    NOT NULL DEFAULT 'QPGMR',
    CRTDATE     DATETIME2(0)    NOT NULL DEFAULT SYSUTCDATETIME(),
    CHGDATE     DATETIME2(0)    NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_OBJECT PRIMARY KEY CLUSTERED (LIBNAME, OBJNAME, OBJTYPE),
    CONSTRAINT UQ_OBJECT_ID UNIQUE (OBJID),
    CONSTRAINT FK_OBJECT_LIB FOREIGN KEY (LIBNAME) REFERENCES QSYS.LIBRARY (LIBNAME),
    CONSTRAINT CK_OBJECT_UPPER CHECK (OBJNAME = UPPER(OBJNAME) AND OBJTYPE = UPPER(OBJTYPE))
);
GO

/*---------------------------------------------------------------------------
  *FILE detail. A physical file is a table; a display file is a screen.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.[FILE]
(
    OBJID       INT             NOT NULL,
    FILETYPE    VARCHAR(4)      NOT NULL,   -- PF | LF | DSPF | PRTF
    RECLEN      INT             NOT NULL DEFAULT 0,
    DSPSIZ_ROWS SMALLINT        NULL,       -- display files: 24 or 27
    DSPSIZ_COLS SMALLINT        NULL,       --                80 or 132
    BASETABLE   NVARCHAR(256)   NULL,       -- PF: the SQL table holding the data
    CONSTRAINT PK_FILE PRIMARY KEY CLUSTERED (OBJID),
    CONSTRAINT FK_FILE_OBJ FOREIGN KEY (OBJID) REFERENCES QSYS.OBJECT (OBJID)
);
GO

/*---------------------------------------------------------------------------
  Physical files have MEMBERS. SQL tables do not, so we carry the member
  name as a column on the data table and filter on it.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.FILE_MEMBER
(
    OBJID       INT             NOT NULL,
    MBRNAME     QSYS.OBJNAME    NOT NULL,
    TEXT        VARCHAR(50)     NOT NULL DEFAULT '',
    CONSTRAINT PK_FILE_MEMBER PRIMARY KEY CLUSTERED (OBJID, MBRNAME),
    CONSTRAINT FK_MBR_FILE FOREIGN KEY (OBJID) REFERENCES QSYS.[FILE] (OBJID)
);
GO

/*---------------------------------------------------------------------------
  Record formats. Every file has at least one; a display file has several,
  and a subfile pair is two formats that know about each other.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.RECORD_FORMAT
(
    FMTID       INT IDENTITY(1,1) NOT NULL,
    OBJID       INT             NOT NULL,
    FMTNAME     QSYS.OBJNAME    NOT NULL,
    FMTSEQ      INT             NOT NULL,
    FMTKIND     VARCHAR(10)     NOT NULL DEFAULT 'RECORD', -- RECORD | SFL | SFLCTL
    SFL_FMT     QSYS.OBJNAME    NULL,       -- SFLCTL -> the subfile it controls
    SFLPAG      SMALLINT        NULL,       -- rows shown per page
    SFLSIZ      SMALLINT        NULL,       -- rows held in the subfile
    TEXT        VARCHAR(50)     NOT NULL DEFAULT '',
    CONSTRAINT PK_RECORD_FORMAT PRIMARY KEY CLUSTERED (FMTID),
    CONSTRAINT UQ_RECORD_FORMAT UNIQUE (OBJID, FMTNAME),
    CONSTRAINT FK_FMT_FILE FOREIGN KEY (OBJID) REFERENCES QSYS.[FILE] (OBJID)
);
GO

/*---------------------------------------------------------------------------
  Fields of a PHYSICAL file record format — the DDS field list.
  DTYPE follows DDS: A char, P packed, S zoned, B binary, L date, T time.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.FIELD
(
    FMTID       INT             NOT NULL,
    FLDSEQ      INT             NOT NULL,
    FLDNAME     QSYS.OBJNAME    NOT NULL,
    DTYPE       CHAR(1)         NOT NULL DEFAULT 'A',
    FLDLEN      SMALLINT        NOT NULL,
    DECPOS      SMALLINT        NULL,
    ISKEY       BIT             NOT NULL DEFAULT 0,
    KEYSEQ      SMALLINT        NULL,
    COLHDG      VARCHAR(60)     NOT NULL DEFAULT '',
    TEXT        VARCHAR(50)     NOT NULL DEFAULT '',
    CONSTRAINT PK_FIELD PRIMARY KEY CLUSTERED (FMTID, FLDSEQ),
    CONSTRAINT UQ_FIELD_NAME UNIQUE (FMTID, FLDNAME),
    CONSTRAINT FK_FIELD_FMT FOREIGN KEY (FMTID) REFERENCES QSYS.RECORD_FORMAT (FMTID)
);
GO

/*---------------------------------------------------------------------------
  Fields of a DISPLAY file record format. These carry a screen position,
  which is the whole point — this table is what the renderer reads.

  FLDKIND  'C' constant (literal text on the screen)
           'F' named field (bound to data)
  USAGE    O output, I input, B both   (DDS position 38)
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.DSPF_FIELD
(
    FMTID       INT             NOT NULL,
    FLDSEQ      INT             NOT NULL,
    FLDKIND     CHAR(1)         NOT NULL,
    FLDNAME     VARCHAR(10)     NOT NULL DEFAULT '',
    DTYPE       CHAR(1)         NOT NULL DEFAULT 'A',
    FLDLEN      SMALLINT        NOT NULL DEFAULT 0,
    DECPOS      SMALLINT        NULL,
    USAGE       CHAR(1)         NOT NULL DEFAULT 'O',
    LIN         SMALLINT        NOT NULL,
    POS         SMALLINT        NOT NULL,
    CONSTANT    VARCHAR(80)     NULL,       -- FLDKIND='C'
    DSPATR      VARCHAR(30)     NOT NULL DEFAULT '',  -- HI, RI, UL, ND, BL
    EDTCDE      VARCHAR(10)     NOT NULL DEFAULT '',
    CONSTRAINT PK_DSPF_FIELD PRIMARY KEY CLUSTERED (FMTID, FLDSEQ),
    CONSTRAINT FK_DSPFFLD_FMT FOREIGN KEY (FMTID) REFERENCES QSYS.RECORD_FORMAT (FMTID),
    CONSTRAINT CK_DSPF_KIND CHECK (FLDKIND IN ('C','F')),
    CONSTRAINT CK_DSPF_USAGE CHECK (USAGE IN ('O','I','B'))
);
GO

/*---------------------------------------------------------------------------
  Source members. DDS and, later, RPG source lives here as 80-column records,
  because that is what it is.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.SRC_MBR
(
    LIBNAME     QSYS.OBJNAME    NOT NULL,
    SRCFILE     QSYS.OBJNAME    NOT NULL,   -- QDDSSRC, QRPGLESRC, QCLSRC
    MBRNAME     QSYS.OBJNAME    NOT NULL,
    SRCSEQ      DECIMAL(6,2)    NOT NULL,
    SRCDAT      CHAR(6)         NOT NULL DEFAULT '000000',
    SRCDTA      VARCHAR(100)    NOT NULL,
    CONSTRAINT PK_SRC_MBR PRIMARY KEY CLUSTERED (LIBNAME, SRCFILE, MBRNAME, SRCSEQ)
);
GO

/*---------------------------------------------------------------------------
  *CMD — a command is an object with a parameter list, which is why the
  AS/400 could prompt any command with F4 without knowing anything about it.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.COMMAND
(
    OBJID       INT             NOT NULL,
    CMDPROC     NVARCHAR(256)   NOT NULL,   -- procedure that implements it
    PROMPT      VARCHAR(50)     NOT NULL DEFAULT '',
    CONSTRAINT PK_COMMAND PRIMARY KEY CLUSTERED (OBJID),
    CONSTRAINT FK_CMD_OBJ FOREIGN KEY (OBJID) REFERENCES QSYS.OBJECT (OBJID)
);
GO

CREATE TABLE QSYS.COMMAND_PARM
(
    OBJID       INT             NOT NULL,
    PARMSEQ     INT             NOT NULL,
    KWD         VARCHAR(10)     NOT NULL,
    PROMPT      VARCHAR(50)     NOT NULL DEFAULT '',
    PARMTYPE    VARCHAR(10)     NOT NULL DEFAULT '*CHAR',
    PARMLEN     SMALLINT        NOT NULL DEFAULT 10,
    DFT         VARCHAR(50)     NULL,
    REQUIRED    BIT             NOT NULL DEFAULT 0,
    CONSTRAINT PK_COMMAND_PARM PRIMARY KEY CLUSTERED (OBJID, PARMSEQ),
    CONSTRAINT FK_CMDPARM_CMD FOREIGN KEY (OBJID) REFERENCES QSYS.COMMAND (OBJID)
);
GO

/*---------------------------------------------------------------------------
  *DTAARA
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.DTAARA
(
    OBJID       INT             NOT NULL,
    DTATYPE     VARCHAR(10)     NOT NULL DEFAULT '*CHAR',
    DTALEN      SMALLINT        NOT NULL DEFAULT 10,
    DTAVAL      VARCHAR(2000)   NOT NULL DEFAULT '',
    CONSTRAINT PK_DTAARA PRIMARY KEY CLUSTERED (OBJID),
    CONSTRAINT FK_DTAARA_OBJ FOREIGN KEY (OBJID) REFERENCES QSYS.OBJECT (OBJID)
);
GO

/*---------------------------------------------------------------------------
  Jobs and the library list. *LIBL resolution is the bit people forget is
  clever: a name is resolved against an ordered list, first hit wins.
---------------------------------------------------------------------------*/
CREATE TABLE QSYS.JOB
(
    JOBID       INT IDENTITY(1,1) NOT NULL,
    JOBNAME     QSYS.OBJNAME    NOT NULL,
    USERNAME    QSYS.OBJNAME    NOT NULL DEFAULT 'QPGMR',
    JOBSTS      VARCHAR(10)     NOT NULL DEFAULT '*ACTIVE',
    CURLIB      QSYS.OBJNAME    NULL,
    STRTIME     DATETIME2(0)    NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_JOB PRIMARY KEY CLUSTERED (JOBID)
);
GO

CREATE TABLE QSYS.LIBL
(
    JOBID       INT             NOT NULL,
    LIBLSEQ     INT             NOT NULL,
    LIBNAME     QSYS.OBJNAME    NOT NULL,
    LIBLPART    VARCHAR(10)     NOT NULL DEFAULT '*USR',  -- *SYS | *CUR | *USR
    CONSTRAINT PK_LIBL PRIMARY KEY CLUSTERED (JOBID, LIBLSEQ),
    CONSTRAINT FK_LIBL_JOB FOREIGN KEY (JOBID) REFERENCES QSYS.JOB (JOBID)
);
GO

/*===========================================================================
  Resolution: given a job and a name, find the object. *LIBL semantics.
===========================================================================*/
GO
CREATE OR ALTER FUNCTION QSYS.RESOLVE_OBJECT
(
    @JOBID   INT,
    @LIBNAME VARCHAR(10),   -- a library name, or *LIBL, or *CURLIB
    @OBJNAME VARCHAR(10),
    @OBJTYPE VARCHAR(10)
)
RETURNS TABLE
AS
RETURN
(
    WITH SEARCHLIST AS
    (
        -- an explicit library: a list of exactly one, at priority 0
        SELECT LIBNAME = UPPER(@LIBNAME), LIBLSEQ = 0
        WHERE  UPPER(@LIBNAME) NOT IN ('*LIBL', '*CURLIB')

        UNION ALL

        -- *CURLIB: the job's current library
        SELECT J.CURLIB, 0
        FROM   QSYS.JOB AS J
        WHERE  J.JOBID = @JOBID
          AND  UPPER(@LIBNAME) = '*CURLIB'
          AND  J.CURLIB IS NOT NULL

        UNION ALL

        -- *LIBL: the job's library list, in order
        SELECT L.LIBNAME, L.LIBLSEQ
        FROM   QSYS.LIBL AS L
        WHERE  L.JOBID = @JOBID
          AND  UPPER(@LIBNAME) = '*LIBL'
    )
    SELECT TOP (1)
           O.OBJID, O.LIBNAME, O.OBJNAME, O.OBJTYPE, O.OBJATTR, O.TEXT
    FROM   SEARCHLIST AS S
    JOIN   QSYS.OBJECT AS O
           ON  O.LIBNAME = S.LIBNAME
           AND O.OBJNAME = UPPER(@OBJNAME)
           AND O.OBJTYPE = UPPER(@OBJTYPE)
    ORDER BY S.LIBLSEQ
);
GO

/*---------------------------------------------------------------------------
  Small helper: create an object and hand back its id.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE QSYS.CRTOBJ
    @LIBNAME VARCHAR(10),
    @OBJNAME VARCHAR(10),
    @OBJTYPE VARCHAR(10),
    @OBJATTR VARCHAR(10) = '',
    @TEXT    VARCHAR(50) = '',
    @OBJID   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM QSYS.LIBRARY WHERE LIBNAME = UPPER(@LIBNAME))
        THROW 50010, N'CPF2110 - Library not found.', 1;

    INSERT QSYS.OBJECT (LIBNAME, OBJNAME, OBJTYPE, OBJATTR, TEXT)
    VALUES (UPPER(@LIBNAME), UPPER(@OBJNAME), UPPER(@OBJTYPE), UPPER(@OBJATTR), @TEXT);

    SET @OBJID = SCOPE_IDENTITY();
END;
GO
