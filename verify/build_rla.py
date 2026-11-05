"""
Slice 2: verifies the positioning algebra of 06_rla.sql and emits
07_demo_rla.sql.

The part worth testing here is not the SQL syntax — it is the algebra:
where the pointer ends up after each operation, and in particular what
happens around duplicate keys, partial keys and the two boundaries. Those
are the things that are wrong in every hand-rolled RLA layer.
"""
import sys
from model import dds, DisplayFile, render, frame, OpenFile

# ---------------------------------------------------------------------------
# STKMOV — stock movements. Keyed on PARTNO and NOT unique: several
# movements per part, which is what makes READE worth having.
# ---------------------------------------------------------------------------

STKMOV_DDS = [
    dds(nametype="R", name="MOVREC", funcs="TEXT('Stock movement')"),
    dds(name="PARTNO", length=10, dtype="A", funcs="COLHDG('Part' 'number')"),
    dds(name="MOVSEQ", length=5,  dtype="P", dec=0, funcs="COLHDG('Seq')"),
    dds(name="MOVDAT", length=10, dtype="A", funcs="COLHDG('Date')"),
    dds(name="MOVTYP", length=3,  dtype="A", funcs="COLHDG('Type')"),
    dds(name="MOVQTY", length=7,  dtype="P", dec=0, funcs="COLHDG('Quantity')"),
    dds(name="MOVREF", length=10, dtype="A", funcs="COLHDG('Reference')"),
    dds(nametype="K", name="PARTNO"),
]

# PARTNO, MOVSEQ, MOVDAT, MOVTYP, MOVQTY, MOVREF
MOVES = [
    ("SIMM16",    1, "1995-03-06", "RCT",  512, "PO-44821"),
    ("SIMM16",    2, "1995-03-21", "ISS",  -96, "WO-10233"),
    ("SIMM16",    3, "1995-04-02", "ISS",  -48, "WO-10391"),
    ("SIMM16",    4, "1995-04-17", "ADJ",  -28, "STK-COUNT"),
    ("CPUP133",   1, "1995-03-11", "RCT",   96, "PO-44903"),
    ("CPUP133",   2, "1995-04-05", "ISS",  -45, "WO-10402"),
    ("NICNE2000", 1, "1995-02-28", "RCT",  420, "PO-44710"),
    ("NICNE2000", 2, "1995-04-11", "ISS",  -10, "WO-10455"),
    ("CBLSER2M",  1, "1995-01-19", "RCT", 1250, "PO-44502"),
    ("MON17CRT",  1, "1995-03-30", "RCT",   25, "PO-45010"),
    ("MON17CRT",  2, "1995-04-14", "ADJ",   -3, "STK-COUNT"),
]

# ---------------------------------------------------------------------------
# MOV100 — movements for one part. CHAIN for the header, SETLL + READE
# for the subfile.
# ---------------------------------------------------------------------------

MOV100_DDS = [
    dds(funcs="DSPSIZ(24 80 *DS3)"),
    dds(funcs="CF03(03 'Exit')"),
    dds(funcs="CF12(12 'Cancel')"),

    dds(nametype="R", name="MOVSFL", funcs="SFL"),
    dds(name="MOVSEQ", length=5,  dtype="P", dec=0, usage="O", lin=7, pos=2,
        funcs="EDTCDE(3)"),
    dds(name="MOVDAT", length=10, dtype="A", usage="O", lin=7, pos=8),
    dds(name="MOVTYP", length=3,  dtype="A", usage="O", lin=7, pos=20),
    dds(name="MOVQTY", length=7,  dtype="P", dec=0, usage="O", lin=7, pos=27,
        funcs="EDTCDE(3)"),
    dds(name="MOVREF", length=10, dtype="A", usage="O", lin=7, pos=38),

    dds(nametype="R", name="MOVCTL", funcs="SFLCTL(MOVSFL)"),
    dds(funcs="SFLSIZ(0999)"),
    dds(funcs="SFLPAG(0010)"),
    dds(lin=1, pos=2,  funcs="'MOV100'"),
    dds(lin=1, pos=33, funcs="'Stock Movements'"),
    dds(name="LIBNAM", length=10, dtype="A", usage="O", lin=1, pos=70),
    dds(lin=2, pos=2,  funcs="'Part . . . . . . . :'"),
    dds(name="PARTNO", length=10, dtype="A", usage="O", lin=2, pos=24,
        funcs="DSPATR(HI)"),
    dds(name="DESCR",  length=30, dtype="A", usage="O", lin=2, pos=36),
    dds(lin=3, pos=2,  funcs="'On hand / system . :'"),
    dds(name="QTYOH",  length=7, dtype="P", dec=0, usage="O", lin=3, pos=24,
        funcs="EDTCDE(3)"),
    dds(lin=3, pos=33, funcs="'/'"),
    dds(name="SYSQTY", length=7, dtype="P", dec=0, usage="O", lin=3, pos=35,
        funcs="EDTCDE(3)"),
    dds(lin=5, pos=2,  funcs="'Seq'"),
    dds(lin=5, pos=8,  funcs="'Date'"),
    dds(lin=5, pos=20, funcs="'Type'"),
    dds(lin=5, pos=26, funcs="'Quantity'"),
    dds(lin=5, pos=38, funcs="'Reference'"),
    dds(lin=6, pos=2,  funcs="'-----'"),
    dds(lin=6, pos=8,  funcs="'----------'"),
    dds(lin=6, pos=20, funcs="'---'"),
    dds(lin=6, pos=27, funcs="'-------'"),
    dds(lin=6, pos=38, funcs="'----------'"),
    dds(name="MSGTXT", length=76, dtype="A", usage="O", lin=22, pos=2,
        funcs="DSPATR(HI)"),
    dds(lin=23, pos=2, funcs="'F3=Exit   F12=Cancel'"),
]


def main():
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}\n     got: {got!r}\n    want: {want!r}")

    # records as the table holds them: RRN in insertion order
    recs = [{"RRN": i, "PARTNO": m[0], "MOVSEQ": m[1], "MOVDAT": m[2],
             "MOVTYP": m[3], "MOVQTY": m[4], "MOVREF": m[5]}
            for i, m in enumerate(MOVES, start=1)]

    def f():
        return OpenFile(recs, ["PARTNO"])

    # ---- SETLL on an exact key ------------------------------------------
    o = f(); o.setll("SIMM16")
    check("SETLL exact sets %EQUAL", o.equal, True)
    check("SETLL positions BEFORE", o.posstate, "BEFORE")
    check("SETLL then READ returns first of the key",
          o.read()["MOVREF"], "PO-44821")

    # ---- SETLL on a key that does not exist ------------------------------
    o = f(); o.setll("HDD12IDE")          # sorts between CPUP133 and MON17CRT
    check("SETLL miss clears %EQUAL", o.equal, False)
    check("SETLL miss lands on the next key up", o.read()["PARTNO"], "MON17CRT")

    # ---- SETLL past the end ---------------------------------------------
    o = f(); o.setll("ZZZZZZ")
    check("SETLL past end is EOF", o.posstate, "EOF")
    check("READ at EOF returns nothing", o.read(), None)
    check("READ at EOF sets %EOF", o.eof, True)

    # ---- SETGT skips the whole key group ---------------------------------
    o = f(); o.setgt("SIMM16")
    check("SETGT skips its own key", o.read(), None)   # SIMM16 is the last key
    o = f(); o.setgt("CBLSER2M")
    check("SETGT lands on the next key", o.read()["PARTNO"], "CPUP133")

    # ---- CHAIN -----------------------------------------------------------
    o = f()
    rec = o.chain("CPUP133")
    check("CHAIN finds", o.found, True)
    check("CHAIN returns lowest RRN of the key", rec["MOVREF"], "PO-44903")
    o2 = f(); o2.setll("MON17CRT"); o2.read()
    before = o2.currrn
    check("failed CHAIN returns nothing", o2.chain("NOSUCH"), None)
    check("failed CHAIN clears %FOUND", o2.found, False)
    check("failed CHAIN leaves the pointer alone", o2.currrn, before)

    # ---- duplicate keys: the whole point of READE ------------------------
    o = f(); o.setll("SIMM16")
    seen = []
    while True:
        r = o.reade("SIMM16")
        if r is None:
            break
        seen.append(r["MOVSEQ"])
    check("READE walks every duplicate in RRN order", seen, [1, 2, 3, 4])
    check("READE off the end sets %EOF", o.eof, True)

    # ---- READE leaving the pointer usable --------------------------------
    o = f(); o.setll("CPUP133")
    o.reade("CPUP133"); o.reade("CPUP133")
    check("READE exhausted its key", o.reade("CPUP133"), None)
    check("a plain READ still moves on", o.read()["PARTNO"], "MON17CRT")

    # ---- partial key on a composite access path --------------------------
    g = OpenFile(recs, ["PARTNO", "MOVSEQ"])
    g.setll("SIMM16")
    check("partial key SETLL", g.read()["MOVSEQ"], 1)
    got = []
    while True:
        r = g.reade("SIMM16")
        if r is None:
            break
        got.append(r["MOVSEQ"])
    check("partial key READE", got, [2, 3, 4])

    # ---- reading backwards -----------------------------------------------
    o = f(); o.setll("SIMM16")
    o.read(); o.read(); o.read()          # seq 1, 2, 3
    check("READP steps back", o.readp()["MOVSEQ"], 2)
    check("READP again", o.readp()["MOVSEQ"], 1)
    check("READP off the front", o.readp()["PARTNO"], "NICNE2000")

    o = f(); o.setll("CBLSER2M")          # the first key in the path
    check("READP from BEFORE the first record", o.readp(), None)
    check("READP at BOF sets %EOF", o.eof, True)

    # READP from a fresh open reads the last record in the path
    o = f()
    o.posstate = "EOF"
    check("READP from EOF returns the last record", o.readp()["PARTNO"], "SIMM16")

    # ---- a full forward walk --------------------------------------------
    o = f(); o.setll()
    walk = []
    while True:
        r = o.read()
        if r is None:
            break
        walk.append((r["PARTNO"], r["MOVSEQ"]))
    check("READ walks the whole access path", len(walk), len(MOVES))
    check("in key order then RRN", walk[:5],
          [("CBLSER2M", 1), ("CPUP133", 1), ("CPUP133", 2),
           ("MON17CRT", 1), ("MON17CRT", 2)])

    # ---- delete leaves the position usable -------------------------------
    o = f(); o.setll("SIMM16"); o.read()
    o.delete()
    check("READ after DELETE continues", o.read()["MOVSEQ"], 2)

    # ---- render MOV100 ---------------------------------------------------
    dspf = DisplayFile(MOV100_DDS)
    check("MOVCTL controls MOVSFL", dspf.formats["MOVCTL"]["sflctl"], "MOVSFL")

    o = f(); o.setll("SIMM16")
    values = {0: {"LIBNAM": "WARELIB", "PARTNO": "SIMM16",
                  "DESCR": "SIMM 16MB 72-pin", "QTYOH": 340, "SYSQTY": 512,
                  "MSGTXT": "4 movements. Net 340 against a system figure of 512."}}
    n = 0
    while True:
        r = o.reade("SIMM16")
        if r is None:
            break
        n += 1
        values[n] = {"MOVSEQ": r["MOVSEQ"], "MOVDAT": r["MOVDAT"],
                     "MOVTYP": r["MOVTYP"], "MOVQTY": r["MOVQTY"],
                     "MOVREF": r["MOVREF"]}

    grid, _ = render(dspf, "MOVCTL", values)
    check("MOV100 header", grid[0][1:7], "MOV100")
    check("MOV100 part", grid[1][23:33], "SIMM16    ")
    check("MOV100 row 1 ref", grid[6][37:47], "PO-44821  ")
    check("MOV100 row 2 qty", grid[7][26:33], "    -96")
    check("MOV100 row 4 type", grid[9][19:22], "ADJ")
    check("MOV100 row 5 empty", grid[10].strip(), "")

    print(frame(grid))
    print()

    if failures:
        print(f"{len(failures)} CHECK(S) FAILED\n")
        for x in failures:
            print(" -", x)
        return 1

    print(f"all checks passed ({len(MOVES)} movements, {len(walk)} walked)")
    emit_sql()
    return 0


# ---------------------------------------------------------------------------

def sqlstr(s):
    return "'" + str(s).replace("'", "''") + "'"


def src_insert(lib, srcfile, mbr, lines):
    rows = ",\n".join(
        f"    ('{lib}', '{srcfile}', '{mbr}', {i:.2f}, {sqlstr(l)})"
        for i, l in enumerate(lines, start=1))
    return ("INSERT QSYS.SRC_MBR (LIBNAME, SRCFILE, MBRNAME, SRCSEQ, SRCDTA) VALUES\n"
            + rows + ";")


def emit_sql():
    moves = ",\n".join(
        "    (" + ", ".join([sqlstr(m[0]), str(m[1]), sqlstr(m[2]),
                             sqlstr(m[3]), str(m[4]), sqlstr(m[5])]) + ")"
        for m in MOVES)

    sql = f"""/*===========================================================================
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
{src_insert('WARELIB', 'QDDSSRC', 'STKMOV', STKMOV_DDS)}
GO

-- -------------------------------------------------------------- MOV100 DDS
{src_insert('WARELIB', 'QDDSSRC', 'MOV100', MOV100_DDS)}
GO

EXEC QSYS.CRTPF   @LIBNAME='WARELIB', @FILENAME='STKMOV', @TEXT='Stock movements';
GO
EXEC QSYS.CRTDSPF @LIBNAME='WARELIB', @FILENAME='MOV100', @TEXT='Stock movement enquiry';
GO

INSERT WARELIB.STKMOV (PARTNO, MOVSEQ, MOVDAT, MOVTYP, MOVQTY, MOVREF) VALUES
{moves};
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
"""
    with open("../sql/07_demo_rla.sql", "w") as fh:
        fh.write(sql)
    print("wrote ../sql/07_demo_rla.sql")


if __name__ == "__main__":
    sys.exit(main())
