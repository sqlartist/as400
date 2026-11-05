"""
Defines the demo, verifies the renderer against it, and emits 05_demo.sql
with the DDS source at exact column positions.
"""
import sys
from model import dds, DisplayFile, render, frame, fmt_field, dds_keyword, dds_constant, dds_split

# ---------------------------------------------------------------------------
# PARTMST — the part master. The warehouse with the plan upside down.
# ---------------------------------------------------------------------------

PARTMST_DDS = [
    dds(nametype="R", name="PARTREC", funcs="TEXT('Part master record')"),
    dds(name="PARTNO", length=10, dtype="A", funcs="COLHDG('Part' 'number')"),
    dds(name="DESCR",  length=30, dtype="A", funcs="COLHDG('Description')"),
    dds(name="BINLOC", length=6,  dtype="A", funcs="COLHDG('Bin' 'location')"),
    dds(name="FLOOR",  length=1,  dtype="A", funcs="COLHDG('Floor')"),
    dds(name="QTYOH",  length=7,  dtype="P", dec=0, funcs="COLHDG('Qty on' 'hand')"),
    dds(name="SYSQTY", length=7,  dtype="P", dec=0, funcs="COLHDG('System' 'qty')"),
    dds(name="UNTCST", length=9,  dtype="P", dec=2, funcs="COLHDG('Unit' 'cost')"),
    dds(nametype="K", name="PARTNO"),
]

# ---------------------------------------------------------------------------
# INQ100 — the inventory enquiry. Subfile over the part master.
# ---------------------------------------------------------------------------

INQ100_DDS = [
    dds(funcs="DSPSIZ(24 80 *DS3)"),
    dds(funcs="CF03(03 'Exit')"),
    dds(funcs="CF12(12 'Cancel')"),

    # ------------------------------------------------------------- subfile
    dds(nametype="R", name="INQSFL", funcs="SFL"),
    dds(name="SELOPT", length=2,  dtype="A", usage="B", lin=7, pos=2),
    dds(name="PARTNO", length=10, dtype="A", usage="O", lin=7, pos=7),
    dds(name="DESCR",  length=30, dtype="A", usage="O", lin=7, pos=18),
    dds(name="BINLOC", length=6,  dtype="A", usage="O", lin=7, pos=49),
    dds(name="QTYOH",  length=7,  dtype="P", dec=0, usage="O", lin=7, pos=57,
        funcs="EDTCDE(3)"),
    dds(name="SYSQTY", length=7,  dtype="P", dec=0, usage="O", lin=7, pos=66,
        funcs="EDTCDE(3)"),

    # ------------------------------------------------------ subfile control
    dds(nametype="R", name="INQCTL", funcs="SFLCTL(INQSFL)"),
    dds(funcs="SFLSIZ(0999)"),
    dds(funcs="SFLPAG(0010)"),
    dds(lin=1,  pos=2,  funcs="'INQ100'"),
    dds(lin=1,  pos=32, funcs="'Inventory Enquiry'"),
    dds(name="LIBNAM", length=10, dtype="A", usage="O", lin=1, pos=70),
    dds(lin=2,  pos=2,  funcs="'Warehouse  . . . . :'"),
    dds(name="WHSE",   length=10, dtype="A", usage="O", lin=2, pos=24),
    dds(lin=3,  pos=2,  funcs="'Position to  . . . :'"),
    dds(name="POSTO",  length=10, dtype="A", usage="B", lin=3, pos=24),
    dds(lin=5,  pos=2,  funcs="'Opt'"),
    dds(lin=5,  pos=7,  funcs="'Part'"),
    dds(lin=5,  pos=18, funcs="'Description'"),
    dds(lin=5,  pos=49, funcs="'Bin'"),
    dds(lin=5,  pos=57, funcs="'On hand'"),
    dds(lin=5,  pos=66, funcs="'System'"),
    dds(lin=6,  pos=2,  funcs="'---'"),
    dds(lin=6,  pos=7,  funcs="'----------'"),
    dds(lin=6,  pos=18, funcs="'------------------------------'"),
    dds(lin=6,  pos=49, funcs="'------'"),
    dds(lin=6,  pos=57, funcs="'-------'"),
    dds(lin=6,  pos=66, funcs="'------'"),
    dds(name="MSGTXT", length=76, dtype="A", usage="O", lin=22, pos=2,
        funcs="DSPATR(HI)"),
    dds(lin=23, pos=2,  funcs="'F3=Exit   F12=Cancel'"),
]

# ---------------------------------------------------------------------------
# The stock. Heavy things upstairs in bins that never fitted them; small
# valuable things downstairs by the door, which is where the variance is.
# ---------------------------------------------------------------------------

PARTS = [
    ("CPQPL2000", "Compaq ProLiant 2000 server",   "U-A-01", "U",    4,     4, 2450.00),
    ("MON17CRT ", "17in CRT monitor",              "U-A-04", "U",   22,    25,  289.00),
    ("PRTLN16  ", "Laser printer LN-16",           "U-B-02", "U",    6,     6,  740.00),
    ("UPS1400  ", "UPS 1400VA",                    "U-B-07", "U",    3,     5,  410.00),
    ("RACK42U  ", "Server rack 42U",               "U-C-01", "U",    2,     2,  980.00),
    ("SIMM16   ", "SIMM 16MB 72-pin",              "D-K-14", "D",  340,   512,   88.50),
    ("CPUP133  ", "CPU Pentium 133",               "D-K-02", "D",   51,    96,  212.00),
    ("HDD12IDE ", "HDD 1.2GB IDE",                 "D-L-08", "D",   88,   104,  134.00),
    ("NICNE2000", "Network card NE2000",           "D-M-03", "D",  410,   420,   24.75),
    ("CBLSER2M ", "Serial cable 2m",               "D-M-22", "D", 1250,  1250,    3.20),
    ("PRNDOT9  ", "Dot matrix printer 9-pin",      "U-B-11", "U",   14,    14,  180.00),
    ("SCN300DPI", "Flatbed scanner 300dpi",        "U-C-05", "U",    7,     8,  320.00),
    ("TAPEDAT4 ", "DAT tape drive 4GB",            "U-A-09", "U",    5,     5,  640.00),
    ("MONI21IN ", "21in CRT monitor",              "U-A-12", "U",    3,     4, 1150.00),
    ("PSU450W  ", "Server PSU 450W",               "U-B-14", "U",   11,    11,  145.00),
    ("KVM8PORT ", "KVM switch 8-port",             "U-C-08", "U",    6,     6,  275.00),
    ("CABTRAY2 ", "Cable tray 2m",                 "U-C-11", "U",   40,    40,   22.00),
    ("SIMM32   ", "SIMM 32MB 72-pin",              "D-K-16", "D",  120,   210,  165.00),
    ("CPUP166  ", "CPU Pentium 166",               "D-K-04", "D",   38,    72,  289.00),
    ("HDD21SCS ", "HDD 2.1GB SCSI",                "D-L-11", "D",   44,    61,  340.00),
    ("FDD144   ", "Floppy drive 1.44MB",           "D-L-02", "D",  260,   268,   18.50),
    ("CDR4X    ", "CD-ROM drive 4x",               "D-L-19", "D",   95,   118,   74.00),
    ("VGA2MB   ", "VGA card 2MB",                  "D-M-07", "D",  155,   190,   62.00),
    ("MOUSEPS2 ", "Mouse PS/2",                    "D-N-01", "D",  480,   520,    9.75),
    ("KBD102   ", "Keyboard 102-key",              "D-N-05", "D",  310,   330,   14.20),
]

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

def main():
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}\n     got: {got!r}\n    want: {want!r}")

    # --- DDS_SPLIT lands on the right columns -----------------------------
    s = dds_split(PARTMST_DDS[1])
    check("DDS_SPLIT name",   s["name"],   "PARTNO")
    check("DDS_SPLIT length", s["length"], "10")
    check("DDS_SPLIT dtype",  s["dtype"],  "A")
    r = dds_split(PARTMST_DDS[0])
    check("DDS_SPLIT nametype R", r["nametype"], "R")
    check("DDS_SPLIT format name", r["name"], "PARTREC")
    k = dds_split(PARTMST_DDS[-1])
    check("DDS_SPLIT nametype K", k["nametype"], "K")

    # --- keyword extraction, including nesting ----------------------------
    check("DDS_KEYWORD SFLCTL", dds_keyword("SFLCTL(INQSFL)", "SFLCTL"), "INQSFL")
    check("DDS_KEYWORD SFLPAG", dds_keyword("SFLPAG(0010)", "SFLPAG"), "0010")
    check("DDS_KEYWORD absent", dds_keyword("SFL", "SFLCTL"), None)
    check("DDS_KEYWORD bare",   dds_keyword("SFL", "SFL"), "")
    check("DDS_KEYWORD nested",
          dds_keyword("CHECK(ME) COLHDG('A' 'B')", "COLHDG"), "'A' 'B'")
    # the argument keeps its case — descriptions should not shout
    check("DDS_KEYWORD keeps case",
          dds_keyword("TEXT('Part master record')", "TEXT"), "'Part master record'")
    check("DDS_KEYWORD case-insensitive match",
          dds_keyword("text('abc')", "TEXT"), "'abc'")

    # --- constants, including the doubled-quote escape ---------------------
    check("DDS_CONSTANT plain", dds_constant("'Inventory Enquiry'"), "Inventory Enquiry")
    check("DDS_CONSTANT escape", dds_constant("'It''s here'"), "It's here")
    check("DDS_CONSTANT none",  dds_constant("DSPATR(HI)"), None)

    # --- field formatting -------------------------------------------------
    check("FMT char pad",      fmt_field("ABC", "A", 6, None, ""), "ABC   ")
    check("FMT char truncate", fmt_field("ABCDEFGH", "A", 4, None, ""), "ABCD")
    # no edit code: a numeric shows its leading zeros, as the machine does
    check("FMT numeric raw",   fmt_field(340, "P", 7, 0, ""), "0000340")
    check("FMT numeric EDTCDE3", fmt_field(340, "P", 7, 0, "3"), "    340")
    check("FMT numeric commas",  fmt_field(1250, "P", 7, 0, "3"), "  1,250")
    check("FMT decimals",      fmt_field(2450.00, "P", 9, 2, ""), "002450.00")
    check("FMT decimals edit", fmt_field(2450.00, "P", 9, 2, "3"), " 2,450.00")
    check("FMT negative",      fmt_field(-5, "P", 5, 0, "3"), "   -5")
    check("FMT zero suppress to blank", fmt_field(0, "P", 5, 0, "4"), "     ")

    # --- compile the display file ----------------------------------------
    dspf = DisplayFile(INQ100_DDS)
    check("DSPSIZ rows", dspf.rows, 24)
    check("DSPSIZ cols", dspf.cols, 80)
    check("formats", sorted(dspf.formats), ["INQCTL", "INQSFL"])
    check("INQSFL kind", dspf.formats["INQSFL"]["kind"], "SFL")
    check("INQCTL kind", dspf.formats["INQCTL"]["kind"], "SFLCTL")
    check("INQCTL controls", dspf.formats["INQCTL"]["sflctl"], "INQSFL")
    check("INQCTL sflpag", dspf.formats["INQCTL"]["sflpag"], 10)
    check("subfile field count", len(dspf.formats["INQSFL"]["fields"]), 6)

    # --- render -----------------------------------------------------------
    values = {0: {"LIBNAM": "WARELIB", "WHSE": "WATFORD", "POSTO": "",
                  "MSGTXT": f"{len(PARTS)} records in PARTMST."}}
    # PARTMST is keyed on PARTNO, so the subfile arrives in key order — the
    # access path decides the sequence, not the order rows were written.
    for i, p in enumerate(sorted(PARTS, key=lambda r: r[0].strip()), start=1):
        values[i] = {"SELOPT": "", "PARTNO": p[0].strip(), "DESCR": p[1],
                     "BINLOC": p[2], "QTYOH": p[4], "SYSQTY": p[5]}

    grid, attr = render(dspf, "INQCTL", values)

    check("grid rows", len(grid), 24)
    check("grid cols", len(grid[0]), 80)
    # header constants landed where the DDS said
    check("line 1 col 2..7", grid[0][1:7], "INQ100")
    check("line 1 col 32", grid[0][31:48], "Inventory Enquiry")
    check("line 1 library", grid[0][69:76], "WARELIB")
    # column headers
    check("hdr Opt", grid[4][1:4], "Opt")
    check("hdr On hand", grid[4][56:63], "On hand")
    # subfile page: 10 rows starting at line 7, in PARTNO key order.
    # Expectations come from the sorted data, so they check the projection
    # rather than restating a hand-copied answer.
    page = sorted(PARTS, key=lambda r: r[0].strip())[:10]
    for n, p in enumerate(page):
        row = grid[6 + n]
        check(f"sfl row {n+1} part", row[6:16],  p[0].strip().ljust(10))
        check(f"sfl row {n+1} desc", row[17:47], p[1].ljust(30))
        check(f"sfl row {n+1} bin",  row[48:54], p[2])
        check(f"sfl row {n+1} qty",  row[56:63], fmt_field(p[4], "P", 7, 0, "3"))
        check(f"sfl row {n+1} sys",  row[65:72], fmt_field(p[5], "P", 7, 0, "3"))
    check("page 1 is a full page", len(page), 10)
    check("there is more than one page", len(PARTS) > 10, True)
    # nothing spilled past the page
    check("line 17 blank", grid[16].strip(), "")
    check("fkeys", grid[22][1:21], "F3=Exit   F12=Cancel")

    # --- SFLPAG really caps the page --------------------------------------
    many = dict(values)
    for i in range(11, 21):
        many[i] = {"PARTNO": "OVERFLOW", "DESCR": "should not appear",
                   "BINLOC": "X-X-99", "QTYOH": 1, "SYSQTY": 1}
    g2, _ = render(dspf, "INQCTL", many)
    check("SFLPAG caps at 10", "OVERFLOW" in "\n".join(g2), False)

    # --- later writes win on overlap --------------------------------------
    overlap = DisplayFile([
        dds(funcs="DSPSIZ(24 80 *DS3)"),
        dds(nametype="R", name="OVL"),
        dds(lin=1, pos=1, funcs="'AAAAAAAAAA'"),
        dds(lin=1, pos=5, funcs="'BBB'"),
    ])
    go, _ = render(overlap, "OVL", {0: {}})
    check("overlap later wins", go[0][:12], "AAAABBBAAA  ")

    # --- print ------------------------------------------------------------
    print(frame(grid))
    print()

    if failures:
        print(f"{len(failures)} CHECK(S) FAILED\n")
        for f in failures:
            print(" -", f)
        return 1

    print("all checks passed")
    emit_sql()
    return 0


# ---------------------------------------------------------------------------
# Emit 05_demo.sql
# ---------------------------------------------------------------------------

def sqlstr(s):
    return "'" + s.replace("'", "''") + "'"


def src_insert(lib, srcfile, mbr, lines):
    out = [f"INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES"]
    rows = []
    for i, l in enumerate(lines, start=1):
        rows.append(f"    ('{lib}', '{srcfile}', '{mbr}', {i * 100 / 100:.2f}, {sqlstr(l)})")
    out.append(",\n".join(rows) + ";")
    return "\n".join(out)


def emit_sql():
    parts_rows = ",\n".join(
        "    (" + ", ".join([
            sqlstr(p[0].strip()), sqlstr(p[1]), sqlstr(p[2]), sqlstr(p[3]),
            str(p[4]), str(p[5]), f"{p[6]:.2f}"
        ]) + ")"
        for p in PARTS
    )

    sql = f"""/*===========================================================================
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
{src_insert('WARELIB', 'QDDSSRC', 'PARTMST', PARTMST_DDS)}
GO

-- -------------------------------------------------------------- INQ100 DDS
{src_insert('WARELIB', 'QDDSSRC', 'INQ100', INQ100_DDS)}
GO

-- ------------------------------------------------------------ compile them
EXEC QSYS.CRTPF   @LIBNAME='WARELIB', @FILENAME='PARTMST', @TEXT='Part master';
GO
EXEC QSYS.CRTDSPF @LIBNAME='WARELIB', @FILENAME='INQ100',  @TEXT='Inventory enquiry';
GO

-- ------------------------------------------------------------------- stock
INSERT WARELIB.PARTMST (PARTNO, DESCR, BINLOC, FLOOR, QTYOH, SYSQTY, UNTCST) VALUES
{parts_rows};
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
"""
    with open("../sql/05_demo.sql", "w") as fh:
        fh.write(sql)
    print("wrote ../sql/05_demo.sql")


if __name__ == "__main__":
    sys.exit(main())
