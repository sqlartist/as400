/*===========================================================================
  AS/400 in SQL Server 2025  —  05: the demo
  ---------------------------------------------------------------------------
  A warehouse where the plan went in upside down. The heavy items are
  upstairs in bins that were never sized for them; the small valuable ones
  are downstairs by the door, which is exactly where the variance between
  QTYOH and SYSQTY turns up.

  Run 01 -> 05 in order, then:

      EXEC WARELIB.INVENQ;

  DDS source below is generated at exact column positions. Do not reformat
  it — the columns are the syntax.
===========================================================================*/

EXEC QSYS.CL 'CRTLIB LIB(WARELIB) TEXT(''Warehouse - Watford'')';
GO

DELETE QSYS.SRC_MBR WHERE LIBNAME = 'WARELIB';
GO

-- ------------------------------------------------------------- PARTMST DDS
INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES
    ('WARELIB', 'QDDSSRC', 'PARTMST', 1.00, '     A          R PARTREC                   TEXT(''Part master record'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 2.00, '     A            PARTNO        10A         COLHDG(''Part'' ''number'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 3.00, '     A            DESCR         30A         COLHDG(''Description'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 4.00, '     A            BINLOC         6A         COLHDG(''Bin'' ''location'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 5.00, '     A            FLOOR          1A         COLHDG(''Floor'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 6.00, '     A            QTYOH          7P 0       COLHDG(''Qty on'' ''hand'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 7.00, '     A            SYSQTY         7P 0       COLHDG(''System'' ''qty'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 8.00, '     A            UNTCST         9P 2       COLHDG(''Unit'' ''cost'')'),
    ('WARELIB', 'QDDSSRC', 'PARTMST', 9.00, '     A          K PARTNO');
GO

-- -------------------------------------------------------------- INQ100 DDS
INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES
    ('WARELIB', 'QDDSSRC', 'INQ100', 1.00, '     A                                      DSPSIZ(24 80 *DS3)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 2.00, '     A                                      CF03(03 ''Exit'')'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 3.00, '     A                                      CF12(12 ''Cancel'')'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 4.00, '     A          R INQSFL                    SFL'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 5.00, '     A            SELOPT         2A  B  7  2'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 6.00, '     A            PARTNO        10A  O  7  7'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 7.00, '     A            DESCR         30A  O  7 18'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 8.00, '     A            BINLOC         6A  O  7 49'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 9.00, '     A            QTYOH          7P 0O  7 57EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 10.00, '     A            SYSQTY         7P 0O  7 66EDTCDE(3)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 11.00, '     A          R INQCTL                    SFLCTL(INQSFL)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 12.00, '     A                                      SFLSIZ(0999)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 13.00, '     A                                      SFLPAG(0010)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 14.00, '     A                                  1  2''INQ100'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 15.00, '     A                                  1 32''Inventory Enquiry'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 16.00, '     A            LIBNAM        10A  O  1 70'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 17.00, '     A                                  2  2''Warehouse  . . . . :'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 18.00, '     A            WHSE          10A  O  2 24'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 19.00, '     A                                  3  2''Position to  . . . :'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 20.00, '     A            POSTO         10A  B  3 24'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 21.00, '     A                                  5  2''Opt'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 22.00, '     A                                  5  7''Part'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 23.00, '     A                                  5 18''Description'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 24.00, '     A                                  5 49''Bin'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 25.00, '     A                                  5 57''On hand'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 26.00, '     A                                  5 66''System'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 27.00, '     A                                  6  2''---'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 28.00, '     A                                  6  7''----------'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 29.00, '     A                                  6 18''------------------------------'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 30.00, '     A                                  6 49''------'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 31.00, '     A                                  6 57''-------'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 32.00, '     A                                  6 66''------'''),
    ('WARELIB', 'QDDSSRC', 'INQ100', 33.00, '     A            MSGTXT        76A  O 22  2DSPATR(HI)'),
    ('WARELIB', 'QDDSSRC', 'INQ100', 34.00, '     A                                 23  2''F3=Exit   F12=Cancel''');
GO

-- ------------------------------------------------------------ compile them
EXEC QSYS.CRTPF   @LIBNAME='WARELIB', @FILENAME='PARTMST', @TEXT='Part master';
GO
EXEC QSYS.CRTDSPF @LIBNAME='WARELIB', @FILENAME='INQ100',  @TEXT='Inventory enquiry';
GO

-- ------------------------------------------------------------------- stock
INSERT WARELIB.PARTMST (PARTNO, DESCR, BINLOC, FLOOR, QTYOH, SYSQTY, UNTCST) VALUES
    ('CPQPL2000', 'Compaq ProLiant 2000 server', 'U-A-01', 'U', 4, 4, 2450.00),
    ('MON17CRT', '17in CRT monitor', 'U-A-04', 'U', 22, 25, 289.00),
    ('PRTLN16', 'Laser printer LN-16', 'U-B-02', 'U', 6, 6, 740.00),
    ('UPS1400', 'UPS 1400VA', 'U-B-07', 'U', 3, 5, 410.00),
    ('RACK42U', 'Server rack 42U', 'U-C-01', 'U', 2, 2, 980.00),
    ('SIMM16', 'SIMM 16MB 72-pin', 'D-K-14', 'D', 340, 512, 88.50),
    ('CPUP133', 'CPU Pentium 133', 'D-K-02', 'D', 51, 96, 212.00),
    ('HDD12IDE', 'HDD 1.2GB IDE', 'D-L-08', 'D', 88, 104, 134.00),
    ('NICNE2000', 'Network card NE2000', 'D-M-03', 'D', 410, 420, 24.75),
    ('CBLSER2M', 'Serial cable 2m', 'D-M-22', 'D', 1250, 1250, 3.20),
    ('PRNDOT9', 'Dot matrix printer 9-pin', 'U-B-11', 'U', 14, 14, 180.00),
    ('SCN300DPI', 'Flatbed scanner 300dpi', 'U-C-05', 'U', 7, 8, 320.00),
    ('TAPEDAT4', 'DAT tape drive 4GB', 'U-A-09', 'U', 5, 5, 640.00),
    ('MONI21IN', '21in CRT monitor', 'U-A-12', 'U', 3, 4, 1150.00),
    ('PSU450W', 'Server PSU 450W', 'U-B-14', 'U', 11, 11, 145.00),
    ('KVM8PORT', 'KVM switch 8-port', 'U-C-08', 'U', 6, 6, 275.00),
    ('CABTRAY2', 'Cable tray 2m', 'U-C-11', 'U', 40, 40, 22.00),
    ('SIMM32', 'SIMM 32MB 72-pin', 'D-K-16', 'D', 120, 210, 165.00),
    ('CPUP166', 'CPU Pentium 166', 'D-K-04', 'D', 38, 72, 289.00),
    ('HDD21SCS', 'HDD 2.1GB SCSI', 'D-L-11', 'D', 44, 61, 340.00),
    ('FDD144', 'Floppy drive 1.44MB', 'D-L-02', 'D', 260, 268, 18.50),
    ('CDR4X', 'CD-ROM drive 4x', 'D-L-19', 'D', 95, 118, 74.00),
    ('VGA2MB', 'VGA card 2MB', 'D-M-07', 'D', 155, 190, 62.00),
    ('MOUSEPS2', 'Mouse PS/2', 'D-N-01', 'D', 480, 520, 9.75),
    ('KBD102', 'Keyboard 102-key', 'D-N-05', 'D', 310, 330, 14.20);
GO

/*---------------------------------------------------------------------------
  INVENQ — read the part master and show it.

  This is the whole point of the slice: the screen is a projection of a
  record format over a result set. Nothing here draws anything.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE WARELIB.INVENQ
    @POSTO VARCHAR(10) = ''
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @V QSYS.FIELD_VALUES;

    -- the control record
    INSERT @V (RRN, FLDNAME, VAL) VALUES
        (0, 'LIBNAM', 'WARELIB'),
        (0, 'WHSE',   'WATFORD'),
        (0, 'POSTO',  @POSTO);

    -- the subfile, one record per line, in key order (SETLL + READE)
    ;WITH P AS
    (
        SELECT RRN = ROW_NUMBER() OVER (ORDER BY PARTNO),
               PARTNO, DESCR, BINLOC, QTYOH, SYSQTY
        FROM   WARELIB.PARTMST
        WHERE  PARTNO >= @POSTO OR @POSTO = ''
    )
    INSERT @V (RRN, FLDNAME, VAL)
    SELECT RRN, F.FLDNAME, F.VAL
    FROM   P
    CROSS APPLY (VALUES ('SELOPT', ''),
                        ('PARTNO', CAST(P.PARTNO AS VARCHAR(256))),
                        ('DESCR',  CAST(P.DESCR  AS VARCHAR(256))),
                        ('BINLOC', CAST(P.BINLOC AS VARCHAR(256))),
                        ('QTYOH',  CAST(P.QTYOH  AS VARCHAR(256))),
                        ('SYSQTY', CAST(P.SYSQTY AS VARCHAR(256)))
                ) AS F (FLDNAME, VAL);

    INSERT @V (RRN, FLDNAME, VAL)
    SELECT 0, 'MSGTXT',
           CAST((SELECT COUNT(*) FROM WARELIB.PARTMST) AS VARCHAR(10)) +
           ' records in PARTMST.';

    EXEC QSYS.SHOW 'WARELIB', 'INQ100', 'INQCTL', @V;
END;
GO
