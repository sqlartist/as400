/*===========================================================================
  AS/400 in SQL Server 2025  —  07: record-level access, demonstrated
  ---------------------------------------------------------------------------
  Two screens, both driven by the access path rather than by a query.

      WARELIB.INVENQR            SETLL *LOVAL then READ until %EOF
      WARELIB.PARTMOV 'SIMM16'   CHAIN for the header, SETLL + READE for
                                 the movements

  INVENQR produces a screen identical to INVENQ from 05. That is the point:
  same output, and the second one never writes a WHERE clause of its own.

  Run after 06_rla.sql.
===========================================================================*/

DELETE QSYS.SRC_MBR WHERE LIBNAME = 'WARELIB' AND MBRNAME IN ('STKMOV','MOV100');
GO

-- -------------------------------------------------------------- STKMOV DDS
INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES
    ('WARELIB', 'QDDSSRC', 'STKMOV', 1.00, '     A          R MOVREC                    TEXT(''Stock movement'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 2.00, '     A            PARTNO        10A         COLHDG(''Part'' ''number'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 3.00, '     A            MOVSEQ         5P 0       COLHDG(''Seq'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 4.00, '     A            MOVDAT        10A         COLHDG(''Date'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 5.00, '     A            MOVTYP         3A         COLHDG(''Type'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 6.00, '     A            MOVQTY         7P 0       COLHDG(''Quantity'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 7.00, '     A            MOVREF        10A         COLHDG(''Reference'')'),
    ('WARELIB', 'QDDSSRC', 'STKMOV', 8.00, '     A          K PARTNO');
GO

-- -------------------------------------------------------------- MOV100 DDS
INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES
    ('WARELIB', 'QDDSSRC', 'MOV100', 1.00, '     A                                      DSPSIZ(24 80 *DS3)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 2.00, '     A                                      CF03(03 ''Exit'')'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 3.00, '     A                                      CF12(12 ''Cancel'')'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 4.00, '     A          R MOVSFL                    SFL'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 5.00, '     A            MOVSEQ         5P 0O  7  2EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 6.00, '     A            MOVDAT        10A  O  7  8'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 7.00, '     A            MOVTYP         3A  O  7 20'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 8.00, '     A            MOVQTY         7P 0O  7 27EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 9.00, '     A            MOVREF        10A  O  7 38'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 10.00, '     A          R MOVCTL                    SFLCTL(MOVSFL)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 11.00, '     A                                      SFLSIZ(0999)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 12.00, '     A                                      SFLPAG(0010)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 13.00, '     A                                  1  2''MOV100'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 14.00, '     A                                  1 33''Stock Movements'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 15.00, '     A            LIBNAM        10A  O  1 70'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 16.00, '     A                                  2  2''Part . . . . . . . :'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 17.00, '     A            PARTNO        10A  O  2 24DSPATR(HI)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 18.00, '     A            DESCR         30A  O  2 36'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 19.00, '     A                                  3  2''On hand / system . :'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 20.00, '     A            QTYOH          7P 0O  3 24EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 21.00, '     A                                  3 33''/'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 22.00, '     A            SYSQTY         7P 0O  3 35EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 23.00, '     A                                  5  2''Seq'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 24.00, '     A                                  5  8''Date'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 25.00, '     A                                  5 20''Type'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 26.00, '     A                                  5 26''Quantity'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 27.00, '     A                                  5 38''Reference'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 28.00, '     A                                  6  2''-----'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 29.00, '     A                                  6  8''----------'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 30.00, '     A                                  6 20''---'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 31.00, '     A                                  6 27''-------'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 32.00, '     A                                  6 38''----------'''),
    ('WARELIB', 'QDDSSRC', 'MOV100', 33.00, '     A            MSGTXT        76A  O 22  2DSPATR(HI)'),
    ('WARELIB', 'QDDSSRC', 'MOV100', 34.00, '     A                                 23  2''F3=Exit   F12=Cancel''');
GO

EXEC QSYS.CRTPF   @LIBNAME='WARELIB', @FILENAME='STKMOV', @TEXT='Stock movements';
GO
EXEC QSYS.CRTDSPF @LIBNAME='WARELIB', @FILENAME='MOV100', @TEXT='Stock movement enquiry';
GO

INSERT WARELIB.STKMOV (PARTNO, MOVSEQ, MOVDAT, MOVTYP, MOVQTY, MOVREF) VALUES
    ('SIMM16', 1, '1995-03-06', 'RCT', 512, 'PO-44821'),
    ('SIMM16', 2, '1995-03-21', 'ISS', -96, 'WO-10233'),
    ('SIMM16', 3, '1995-04-02', 'ISS', -48, 'WO-10391'),
    ('SIMM16', 4, '1995-04-17', 'ADJ', -28, 'STK-COUNT'),
    ('CPUP133', 1, '1995-03-11', 'RCT', 96, 'PO-44903'),
    ('CPUP133', 2, '1995-04-05', 'ISS', -45, 'WO-10402'),
    ('NICNE2000', 1, '1995-02-28', 'RCT', 420, 'PO-44710'),
    ('NICNE2000', 2, '1995-04-11', 'ISS', -10, 'WO-10455'),
    ('CBLSER2M', 1, '1995-01-19', 'RCT', 1250, 'PO-44502'),
    ('MON17CRT', 1, '1995-03-30', 'RCT', 25, 'PO-45010'),
    ('MON17CRT', 2, '1995-04-14', 'ADJ', -3, 'STK-COUNT');
GO

/*---------------------------------------------------------------------------
  INVENQR — the inventory enquiry again, this time walking the access path.

  Compare with INVENQ in 05_demo.sql. Same screen, same order. The ordering
  is not asked for here: it falls out of the keyed access path.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.INVENQR
    @POSTO VARCHAR(10) = ''
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @O INT, @V QSYS.FIELD_VALUES, @N INT = 0;
    EXEC QSYS.OPNDBF 'WARELIB/PARTMST', NULL, @O OUTPUT;

    IF @POSTO = '' EXEC QSYS.SETLL @O;              -- *LOVAL
    ELSE           EXEC QSYS.SETLL @O, @POSTO;

    WHILE 1 = 1
    BEGIN
        EXEC QSYS.READ_REC @O;
        IF QSYS.PCT_EOF(@O) = 1 BREAK;

        SET @N = @N + 1;
        IF @N > 10 BREAK;                            -- SFLPAG

        INSERT @V (RRN, FLDNAME, VAL)
        SELECT @N, FLDNAME, VAL FROM QSYS.BUF(@O)
        WHERE  FLDNAME IN ('PARTNO','DESCR','BINLOC','QTYOH','SYSQTY');
    END;

    INSERT @V (RRN, FLDNAME, VAL) VALUES
        (0, 'LIBNAM', 'WARELIB'),
        (0, 'WHSE',   'WATFORD'),
        (0, 'POSTO',  @POSTO),
        (0, 'MSGTXT', CAST(@N AS VARCHAR(10)) + ' records read from the access path.');

    EXEC QSYS.CLOF @O;
    EXEC QSYS.SHOW 'WARELIB', 'INQ100', 'INQCTL', @V;
END;
GO

/*---------------------------------------------------------------------------
  PARTMOV — CHAIN the part, then READE its movements.

  This is the idiom every RPG programmer has typed a thousand times, and the
  reason the RRN tiebreak in the access path matters: STKMOV is keyed on
  PARTNO and that key is NOT unique.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.PARTMOV
    @PARTNO VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @P INT, @M INT, @V QSYS.FIELD_VALUES, @N INT = 0;

    ------------------------------------------------------------- the header
    EXEC QSYS.OPNDBF 'WARELIB/PARTMST', NULL, @P OUTPUT;
    EXEC QSYS.CHAIN @P, @PARTNO;

    IF QSYS.PCT_FOUND(@P) = 0
    BEGIN
        EXEC QSYS.CLOF @P;
        PRINT 'CPF5001 - Part ' + @PARTNO + ' not found in PARTMST.';
        RETURN;
    END;

    INSERT @V (RRN, FLDNAME, VAL)
    SELECT 0, FLDNAME, VAL FROM QSYS.BUF(@P)
    WHERE  FLDNAME IN ('PARTNO','DESCR','QTYOH','SYSQTY');

    ---------------------------------------------------------- the movements
    EXEC QSYS.OPNDBF 'WARELIB/STKMOV', NULL, @M OUTPUT;
    EXEC QSYS.SETLL @M, @PARTNO;

    WHILE 1 = 1
    BEGIN
        EXEC QSYS.READ_REC @M, @PRIOR = 0, @K1 = @PARTNO;   -- READE
        IF QSYS.PCT_EOF(@M) = 1 BREAK;

        SET @N = @N + 1;
        IF @N > 10 BREAK;

        INSERT @V (RRN, FLDNAME, VAL)
        SELECT @N, FLDNAME, VAL FROM QSYS.BUF(@M)
        WHERE  FLDNAME IN ('MOVSEQ','MOVDAT','MOVTYP','MOVQTY','MOVREF');
    END;

    INSERT @V (RRN, FLDNAME, VAL) VALUES
        (0, 'LIBNAM', 'WARELIB'),
        (0, 'MSGTXT', CAST(@N AS VARCHAR(10)) + ' movements read with READE.');

    EXEC QSYS.CLOF @P;
    EXEC QSYS.CLOF @M;
    EXEC QSYS.SHOW 'WARELIB', 'MOV100', 'MOVCTL', @V;
END;
GO
