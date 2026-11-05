"""
Executable model of the T-SQL in ../sql.

This is not a rewrite of the project in Python. It is a line-for-line model of
the four pieces of logic that are easy to get wrong in SQL and impossible to
eyeball:

    QSYS.DDS_SPLIT      column offsets
    QSYS.DDS_KEYWORD    keyword(argument) extraction with nesting
    QSYS.DDS_CONSTANT   quoted literal with doubled-quote escape
    QSYS.FMT_FIELD      field formatting, including leading zeros
    QSYS.RENDER         write list -> characters -> overlap -> 24x80 grid

If the grid this produces is right, the set-based version in 03_render.sql is
doing the same arithmetic. It also emits the DDS source at exact column
positions, which is how 05_demo.sql gets its text.
"""

from decimal import Decimal, ROUND_HALF_UP

# ---------------------------------------------------------------------------
# DDS source construction — exact column positions
#
#   1-5 seq | 6 form | 7 comment | 8-16 cond | 17 nametype | 18 rsvd
#   19-28 name | 29-30 ref | 31-34 length | 35 type | 36-37 dec | 38 usage
#   39-41 line | 42-44 pos | 45-80 functions
# ---------------------------------------------------------------------------

def dds(nametype=" ", name="", length="", dtype=" ", dec="", usage=" ",
        lin="", pos="", funcs=""):
    line = [" "] * 80
    line[5] = "A"                                    # position 6
    line[16] = nametype                              # position 17
    for i, c in enumerate(f"{name:<10}"[:10]):       # 19-28
        line[18 + i] = c
    for i, c in enumerate(f"{str(length):>4}"[:4]):  # 31-34
        line[30 + i] = c
    line[34] = dtype                                 # 35
    for i, c in enumerate(f"{str(dec):>2}"[:2]):     # 36-37
        line[35 + i] = c
    line[37] = usage                                 # 38
    for i, c in enumerate(f"{str(lin):>3}"[:3]):     # 39-41
        line[38 + i] = c
    for i, c in enumerate(f"{str(pos):>3}"[:3]):     # 42-44
        line[41 + i] = c
    for i, c in enumerate(funcs[:36]):               # 45-80
        line[44 + i] = c
    return "".join(line).rstrip()


# ---------------------------------------------------------------------------
# QSYS.DDS_SPLIT
# ---------------------------------------------------------------------------

def dds_split(src):
    L = (src + " " * 80)[:80]
    return {
        "formtype": L[5],
        "iscomment": 1 if L[6] == "*" else 0,
        "nametype": L[16],
        "name": L[18:28].strip().upper(),
        "length": L[30:34].strip(),
        "dtype": L[34],
        "dec": L[35:37].strip(),
        "usage": L[37],
        "lin": L[38:41].strip(),
        "pos": L[41:44].strip(),
        "funcs": L[44:80].rstrip(),
    }


# ---------------------------------------------------------------------------
# QSYS.DDS_KEYWORD
# ---------------------------------------------------------------------------

def dds_keyword(funcs, kwd):
    # Search case-insensitively but slice from the ORIGINAL, so that
    # TEXT('Part master record') keeps its case instead of shouting.
    f = " " + (funcs or "").strip()
    u = f.upper()
    k = " " + kwd.upper()
    at = u.find(k)
    if at < 0:
        return None
    after = at + len(k)
    if after >= len(u) or u[after] != "(":
        return ""
    i, depth = after + 1, 1
    while i < len(u) and depth > 0:
        if u[i] == "(":
            depth += 1
        elif u[i] == ")":
            depth -= 1
        if depth > 0:
            i += 1
    return f[after + 1:i]


# ---------------------------------------------------------------------------
# QSYS.DDS_CONSTANT
# ---------------------------------------------------------------------------

def dds_constant(funcs):
    f = (funcs or "").strip()
    if not f.startswith("'"):
        return None
    out, i = [], 1
    while i < len(f):
        c = f[i]
        if c == "'":
            if i + 1 < len(f) and f[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            break
        out.append(c)
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# QSYS.FMT_FIELD
# ---------------------------------------------------------------------------

def fmt_field(val, dtype, length, dec, edtcde):
    if length <= 0:
        return ""
    edtcde = (edtcde or "").strip().upper()

    if dtype.upper() in ("P", "S", "B"):
        d = dec or 0
        n = Decimal(str(val if val not in (None, "") else 0))
        neg = n < 0
        scaled = (abs(n) * (Decimal(10) ** d)).quantize(Decimal(1), ROUND_HALF_UP)
        digits = str(scaled).rjust(length, "0")[-length:]
        out = f"{digits[:length - d]}.{digits[-d:]}" if d > 0 else digits

        if edtcde in ("1", "2", "3", "4", "J", "Z"):
            ipart = out[:len(out) - d - 1] if d > 0 else out
            fpart = out[-(d + 1):] if d > 0 else ""
            ipart = ipart.lstrip("0") or "0"
            if ipart == "0" and edtcde in ("2", "4"):
                ipart = ""
            if edtcde in ("1", "2", "3", "4") and len(ipart) > 3:
                groups, i = [], len(ipart)
                while i > 0:
                    groups.insert(0, ipart[max(0, i - 3):i])
                    i -= 3
                ipart = ",".join(groups)
            out = ipart + fpart

        if neg:
            out = "-" + out
        out = out[-length:] if len(out) > length else out
        return out.rjust(length)

    out = "" if val is None else str(val)
    return out[:length].ljust(length)


# ---------------------------------------------------------------------------
# A tiny catalog, matching the shape of the SQL tables
# ---------------------------------------------------------------------------

class DisplayFile:
    def __init__(self, source):
        self.rows, self.cols = 24, 80
        self.formats = {}          # name -> dict
        self.order = []
        self._compile(source)

    def _compile(self, source):
        parsed = [dds_split(s) for s in source]
        parsed = [p for p in parsed if not p["iscomment"]]

        first_r = next((i for i, p in enumerate(parsed) if p["nametype"] == "R"), len(parsed))
        for p in parsed[:first_r]:
            ds = dds_keyword(p["funcs"], "DSPSIZ")
            if ds:
                bits = ds.split()
                self.rows, self.cols = int(bits[0]), int(bits[1])

        starts = [i for i, p in enumerate(parsed) if p["nametype"] == "R"]
        for n, start in enumerate(starts):
            end = starts[n + 1] if n + 1 < len(starts) else len(parsed)
            name = parsed[start]["name"]

            funcs = parsed[start]["funcs"]
            for p in parsed[start + 1:end]:
                if p["nametype"] == " " and not p["name"] and not p["lin"] and not p["pos"]:
                    funcs += " " + p["funcs"]

            kind = "RECORD"
            if dds_keyword(funcs, "SFLCTL") is not None:
                kind = "SFLCTL"
            elif dds_keyword(funcs, "SFL") is not None:
                kind = "SFL"

            fmt = {
                "name": name,
                "seq": n + 1,
                "kind": kind,
                "sflctl": (dds_keyword(funcs, "SFLCTL") or "").strip() or None,
                "sflpag": int(dds_keyword(funcs, "SFLPAG")) if dds_keyword(funcs, "SFLPAG") else None,
                "sflsiz": int(dds_keyword(funcs, "SFLSIZ")) if dds_keyword(funcs, "SFLSIZ") else None,
                "fields": [],
            }

            for p in parsed[start + 1:end]:
                if p["nametype"] != " ":
                    continue
                if not p["lin"].isdigit() or not p["pos"].isdigit():
                    continue
                const = dds_constant(p["funcs"])
                fmt["fields"].append({
                    "seq": len(fmt["fields"]) + 1,
                    "kind": "C" if not p["name"] else "F",
                    "name": p["name"],
                    "dtype": p["dtype"] if p["dtype"] != " " else "A",
                    "len": int(p["length"]) if p["length"].isdigit() else len(const or ""),
                    "dec": int(p["dec"]) if p["dec"].isdigit() else None,
                    "usage": p["usage"] if p["usage"] in ("I", "O", "B") else "O",
                    "lin": int(p["lin"]),
                    "pos": int(p["pos"]),
                    "const": const,
                    "dspatr": dds_keyword(p["funcs"], "DSPATR") or "",
                    "edtcde": dds_keyword(p["funcs"], "EDTCDE") or "",
                })

            self.formats[name] = fmt
            self.order.append(name)


# ---------------------------------------------------------------------------
# QSYS.RENDER
# ---------------------------------------------------------------------------

def render(dspf, fmtname, values):
    """values: {0: {FLD: val}, 1: {...}, 2: {...}}  — key 0 is the record,
    keys 1..n are subfile records."""
    ctl = dspf.formats[fmtname]
    draw = [ctl]
    if ctl["sflctl"] and ctl["sflctl"] in dspf.formats:
        draw.append(dspf.formats[ctl["sflctl"]])
    sflpag = ctl["sflpag"] or 0

    writes = []           # (lin, pos, text, attr) in draw order
    for fmt in draw:
        if fmt["kind"] == "SFL":
            for rrn in sorted(k for k in values if k > 0):
                if sflpag and rrn > sflpag:
                    continue
                for f in fmt["fields"]:
                    if f["kind"] != "C" and f["usage"] not in ("O", "B"):
                        continue
                    txt = (f["const"] if f["kind"] == "C"
                           else fmt_field(values[rrn].get(f["name"]), f["dtype"],
                                          f["len"], f["dec"], f["edtcde"]))
                    writes.append((f["lin"] + rrn - 1, f["pos"], txt or "", f["dspatr"]))
        else:
            for f in fmt["fields"]:
                if f["kind"] != "C" and f["usage"] not in ("O", "B"):
                    continue
                txt = (f["const"] if f["kind"] == "C"
                       else fmt_field(values.get(0, {}).get(f["name"]), f["dtype"],
                                      f["len"], f["dec"], f["edtcde"]))
                writes.append((f["lin"], f["pos"], txt or "", f["dspatr"]))

    writes = [w for w in writes
              if 1 <= w[0] <= dspf.rows and 1 <= w[1] <= dspf.cols and len(w[2]) > 0]

    grid = [[" "] * dspf.cols for _ in range(dspf.rows)]
    attr = [[" "] * dspf.cols for _ in range(dspf.rows)]
    for lin, pos, txt, a in writes:          # later writes win
        for i, ch in enumerate(txt):
            p = pos + i
            if p > dspf.cols:
                break
            grid[lin - 1][p - 1] = ch
            attr[lin - 1][p - 1] = ("H" if "HI" in a else
                                    "R" if "RI" in a else
                                    "U" if "UL" in a else
                                    "N" if "ND" in a else ".")
    return ["".join(r) for r in grid], ["".join(r) for r in attr]


def frame(lines, cols=80):
    out = ["+" + "-" * cols + "+"]
    out += ["|" + l.ljust(cols)[:cols] + "|" for l in lines]
    out += ["+" + "-" * cols + "+"]
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Access path and record-level access — a model of 06_rla.sql
#
# The position is a relative record number plus a state, nothing else. The
# order is (key fields..., RRN); the RRN tiebreak is what makes duplicate
# keys work.
# ---------------------------------------------------------------------------

class OpenFile:
    def __init__(self, records, keyflds):
        """records: list of dicts, each with 'RRN'. keyflds: key field names."""
        self.recs = {r["RRN"]: r for r in records}
        self.keys = keyflds
        self.posstate = "BOF"
        self.currrn = None
        self.buf = None
        self.found = self.eof = self.equal = False

    # ---- the access path -------------------------------------------------
    def _sortkey(self, r):
        return tuple(r[k] for k in self.keys) + (r["RRN"],)

    def _path(self):
        return sorted(self.recs.values(), key=self._sortkey)

    def _prefix(self, r, n):
        return tuple(r[k] for k in self.keys[:n])

    def _begin(self):
        self.found = self.eof = self.equal = False
        self.buf = None

    # ---- positioning -----------------------------------------------------
    def setll(self, *key):
        self._begin()
        if not key:
            self.posstate, self.currrn = "BOF", None
            return
        n = len(key)
        hit = next((r for r in self._path() if self._prefix(r, n) >= tuple(key)), None)
        self.posstate = "BEFORE" if hit else "EOF"
        self.currrn = hit["RRN"] if hit else None
        self.equal = any(self._prefix(r, n) == tuple(key) for r in self.recs.values())

    def setgt(self, *key):
        self._begin()
        n = len(key)
        hit = next((r for r in self._path() if self._prefix(r, n) > tuple(key)), None)
        self.posstate = "BEFORE" if hit else "EOF"
        self.currrn = hit["RRN"] if hit else None

    def chain(self, *key):
        self._begin()
        n = len(key)
        hits = [r for r in self._path() if self._prefix(r, n) == tuple(key)]
        if not hits:
            return None                      # pointer unchanged, %FOUND off
        rec = min(hits, key=lambda r: r["RRN"])
        self.posstate, self.currrn = "AT", rec["RRN"]
        self.buf, self.found, self.equal = rec, True, True
        return rec

    # ---- reading ---------------------------------------------------------
    def _candidates(self, prior):
        path = self._path()
        if prior:
            path = list(reversed(path))
        if self.posstate == "BOF":
            return path if not prior else []
        if self.posstate == "EOF":
            return path if prior else []
        cur = self.recs[self.currrn]
        ck = self._sortkey(cur)
        if self.posstate == "BEFORE" and not prior:
            # the record we are positioned before IS the next one
            return [r for r in path if self._sortkey(r) >= ck]
        if prior:
            return [r for r in path if self._sortkey(r) < ck]
        return [r for r in path if self._sortkey(r) > ck]

    def _read(self, prior=False, key=None):
        self._begin()
        if (not prior and self.posstate == "EOF") or (prior and self.posstate == "BOF"):
            self.eof = True
            return None

        cands = self._candidates(prior)
        if key is not None:
            n = len(key)
            cands = [r for r in cands if self._prefix(r, n) == tuple(key)]

        if not cands:
            self.eof = True
            if key is None:               # a plain READ runs off the end
                self.posstate = "BOF" if prior else "EOF"
                self.currrn = None
            return None                   # READE leaves the pointer alone

        rec = cands[0]
        self.posstate, self.currrn = "AT", rec["RRN"]
        self.buf, self.found = rec, True
        return rec

    def read(self):            return self._read()
    def readp(self):           return self._read(prior=True)
    def reade(self, *key):     return self._read(key=key)
    def readpe(self, *key):    return self._read(prior=True, key=key)

    # ---- mutation --------------------------------------------------------
    def delete(self):
        if self.posstate != "AT":
            raise RuntimeError("CPF5030 - No record read for delete.")
        # Step the pointer back to the PRIOR record before removing this one.
        # Leaving it on the deleted record would make the next READ find
        # nothing to compare against and report a false end of file, which
        # would stop a read-and-delete loop after its first record.
        cur = self._sortkey(self.recs[self.currrn])
        prior = [r for r in self._path() if self._sortkey(r) < cur]
        self.recs.pop(self.currrn)
        if prior:
            self.posstate, self.currrn = "AT", prior[-1]["RRN"]
        else:
            self.posstate, self.currrn = "BOF", None
        self.found = True
