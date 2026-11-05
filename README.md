# AS/400 in SQL Server 2025 — the green screen and the access path

The first vertical slice. An object catalog, a DDS compiler, a 5250
character-grid renderer, a handful of CL commands, and one real screen: an
inventory enquiry over a warehouse where the plan went in upside down.

Slice 2 adds record-level access. No RPG yet — everything here is machinery the RPG work
will sit on top of.

## Run order

```
00_reset_warelib.sql  clears WARELIB so 05/07 can be re-run
01_catalog.sql        QSYS object catalog, *LIBL resolution
02_dds.sql            DDS compiler — CRTPF and CRTDSPF
03_render.sql         the 5250 renderer
04_cl.sql             CL parser, commands, WRKLIB/WRKOBJ/DSPFFD/DSPPFM/DLTF
05_demo.sql           WARELIB, PARTMST, INQ100 and the data
06_rla.sql            record-level access — SETLL/CHAIN/READ/READE/...
07_demo_rla.sql       STKMOV, MOV100, and the same enquiry driven by RLA
08_input.sql          screen input, job state, indicators, subfile paging
09_inqpgm.sql         INQ100 as an interactive program
```

## The terminal

```
cd client
python term5250.py                     offline, no database needed
python term5250.py --sql --server localhost --database AS400
```

Enter sends. Tab moves between input fields. Page Down and Page Up roll the
subfile. Type `5` against a part and press Enter to see its movements, F12 to
come back, F3 to end the job.

The client draws what the host sent and collects what you typed; it decides
nothing. That is not a simplification, it is what a block-mode terminal is:
while you are typing, the host knows nothing about it. Only an AID key sends
the buffer back.

Which is why a program here is not a loop waiting on input. It is a state
machine called once per keypress — and that is something a stored procedure
can be. `WARELIB.WSPGM` is the whole interactive application.

For SQL mode you need a driver: `pip install pyodbc` (most likely to already
work on Windows), or `pymssql`, or `python-tds` for a pure-Python one.

Then:

```sql
EXEC WARELIB.INVENQ;                  -- the screen, built set-based
EXEC WARELIB.INVENQR;                 -- the same screen, SETLL + READ
EXEC WARELIB.PARTMOV 'SIMM16';        -- CHAIN + READE over duplicate keys
EXEC QSYS.CL 'WRKOBJ OBJ(WARELIB/*ALL)';
EXEC QSYS.CL 'DSPFFD FILE(WARELIB/PARTMST)';
EXEC QSYS.CL 'DLTF FILE(WARELIB/MOV100)';
```

`05_demo.sql` prints to the messages tab. In SSMS switch results to text, or
just watch the Messages pane.

## Three ideas

**DDS is column-positional, so there is no parser.** The meaning of a
character is decided by where it sits — name at 19-28, length at 31-34, type
at 35, screen line at 39-41, position at 42-44. `QSYS.DDS_SPLIT` is six
`SUBSTRING` calls. This is the single biggest reason the AS/400 is a
friendlier target than anything else rebuilt in SQL.

**A 5250 screen is a projection, not a drawing.** Every field already knows
its line and position, so rendering is: turn fields into writes, explode
writes into characters, let later writes win where they overlap, left join
onto a 24x80 grid, `STRING_AGG` each row. Entirely set-based. Nothing paints.

**A keyed physical file is an index.** `CRTPF` builds a table plus a
clustered index on the DDS key fields, and that index *is* the access path.
`SETLL`/`CHAIN`/`READ`/`READE` drive it directly rather than faking one.

**Position is a relative record number and nothing else.** An open file
keeps `POSSTATE` (BOF / BEFORE / AT / EOF) and one RRN. Every key value an
operation needs is read back out of the record itself, so there is no cached
key tuple to go stale when somebody updates a key field underneath you.

**The RRN tiebreak is what makes duplicate keys work.** The access path
orders by (key fields..., RRN), so two records with the same key are still
strictly ordered — which is exactly what lets `READE` walk all of them and
stop cleanly. SQL Server has no row-value comparison, so the tuple predicate
is generated from the catalog, nested inside-out.

## Deliberate compromises

- **Attribute plane.** On a real 5250 each field is preceded by an attribute
  byte that occupies a screen position. We keep attributes in a parallel
  plane so text lands exactly where the DDS says. Layout fidelity over wire
  fidelity — revisit if you ever emulate the datastream itself.
- **Packed and zoned decimal are `DECIMAL`.** On the machine they are byte
  layouts, which is what lets RPG overlay a packed field with characters in a
  data structure. That needs the record-image work (`VARBINARY` plus
  DDS-derived projections) and belongs with RPG, not here.
- **No EBCDIC yet.** Collation is the real issue, not the characters —
  lowercase sorts before uppercase and digits sort after letters. Needs a
  computed EBCDIC key column or a custom collation.
- **Multi-member files** carry `MBRNAME` on the table but nothing yet reads
  it. Partitioned views when it matters.


## Next

1. Logical files — `CRTLF` over a physical file with select/omit, which is
   a filtered index and a second access path.
3. `CRTRPGPGM` — fixed-format RPG III to an IR stored in the `*PGM` object,
   then a generated stored procedure. Translate at create time, like TIMI.
