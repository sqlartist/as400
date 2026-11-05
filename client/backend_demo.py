"""
Offline backend.

Runs the same program logic as 09_inqpgm.sql against the Python model, so
the terminal works with nothing installed and no SQL Server. Useful for
seeing the thing, and for testing the client without a database.

The SQL backend is the real one; this exists so the terminal is never the
part that is broken.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "verify"))

from model import DisplayFile, render, OpenFile          # noqa: E402
from build_demo import INQ100_DDS, PARTS                 # noqa: E402
from build_rla import MOV100_DDS, MOVES                  # noqa: E402

PAGE = 10


def _parts():
    return [{"RRN": i, "PARTNO": p[0].strip(), "DESCR": p[1], "BINLOC": p[2],
             "FLOOR": p[3], "QTYOH": p[4], "SYSQTY": p[5], "UNTCST": p[6]}
            for i, p in enumerate(PARTS, start=1)]


def _moves():
    return [{"RRN": i, "PARTNO": m[0], "MOVSEQ": m[1], "MOVDAT": m[2],
             "MOVTYP": m[3], "MOVQTY": m[4], "MOVREF": m[5]}
            for i, m in enumerate(MOVES, start=1)]


class DemoBackend:
    def __init__(self):
        self.inq = DisplayFile(INQ100_DDS)
        self.mov = DisplayFile(MOV100_DDS)
        self.pgm = "INQ100"
        self.stack = None
        self.ctx = None
        self.pageno = 1
        self.sfl = []           # the subfile: a list of record dicts
        self.msg = ""

    # -- the access path ---------------------------------------------------
    def _page(self, anchor=None, backward=False, gt=False):
        f = OpenFile(_parts(), ["PARTNO"])
        rows = []
        if not backward:
            if anchor is None:
                f.setll()
            elif gt:
                f.setgt(anchor)
            else:
                f.setll(anchor)
            while len(rows) < PAGE:
                r = f.read()
                if r is None:
                    break
                rows.append(r)
        else:
            f.setll(anchor)
            while len(rows) < PAGE:
                r = f.readp()
                if r is None:
                    break
                rows.append(r)
            rows.reverse()
        return rows

    def _top(self):
        return self.sfl[0]["PARTNO"] if self.sfl else None

    def _end(self):
        return self.sfl[-1]["PARTNO"] if self.sfl else None

    # -- input map ---------------------------------------------------------
    @staticmethod
    def _inputs(dspf, ctlname, sflrows):
        ctl = dspf.formats[ctlname]
        out = []
        for f in ctl["fields"]:
            if f["kind"] == "F" and f["usage"] in ("I", "B"):
                out.append({"name": f["name"], "rrn": 0, "lin": f["lin"],
                            "pos": f["pos"], "len": f["len"]})
        sflname = ctl.get("sflctl")
        if sflname and sflname in dspf.formats:
            for n in range(1, sflrows + 1):
                for f in dspf.formats[sflname]["fields"]:
                    if f["kind"] == "F" and f["usage"] in ("I", "B"):
                        out.append({"name": f["name"], "rrn": n,
                                    "lin": f["lin"] + n - 1,
                                    "pos": f["pos"], "len": f["len"]})
        out.sort(key=lambda g: (g["lin"], g["pos"]))
        return out

    # -- the screens -------------------------------------------------------
    def _show_inq(self):
        values = {0: {"LIBNAM": "WARELIB", "WHSE": "WATFORD", "POSTO": "",
                      "MSGTXT": self.msg}}
        for n, r in enumerate(self.sfl, start=1):
            values[n] = {"SELOPT": "", "PARTNO": r["PARTNO"], "DESCR": r["DESCR"],
                         "BINLOC": r["BINLOC"], "QTYOH": r["QTYOH"],
                         "SYSQTY": r["SYSQTY"]}
        rows, attrs = render(self.inq, "INQCTL", values)
        return {"rows": rows, "attrs": attrs,
                "inputs": self._inputs(self.inq, "INQCTL", len(self.sfl))}

    def _show_mov(self, partno):
        part = next((p for p in _parts() if p["PARTNO"] == partno), None)
        values = {0: {"LIBNAM": "WARELIB",
                      "PARTNO": partno,
                      "DESCR": part["DESCR"] if part else "",
                      "QTYOH": part["QTYOH"] if part else 0,
                      "SYSQTY": part["SYSQTY"] if part else 0}}
        f = OpenFile(_moves(), ["PARTNO"])
        f.setll(partno)
        n = 0
        while n < PAGE:
            r = f.reade(partno)
            if r is None:
                break
            n += 1
            values[n] = {"MOVSEQ": r["MOVSEQ"], "MOVDAT": r["MOVDAT"],
                         "MOVTYP": r["MOVTYP"], "MOVQTY": r["MOVQTY"],
                         "MOVREF": r["MOVREF"]}
        values[0]["MSGTXT"] = f"{n} movements read with READE.  F12=Back"
        rows, attrs = render(self.mov, "MOVCTL", values)
        return {"rows": rows, "attrs": attrs,
                "inputs": self._inputs(self.mov, "MOVCTL", n)}

    # -- the contract ------------------------------------------------------
    def open(self):
        self.sfl = self._page()
        self.msg = "Type 5 against a part to see its movements."
        return self._show_inq()

    def submit(self, aid, fields):
        if aid == "F3":
            return None

        if self.pgm == "MOV100":
            if aid == "F12":
                self.pgm, self.stack = self.stack or "INQ100", None
                self.msg = ""
                return self._show_inq()
            return self._show_mov(self.ctx)

        sel = next((f for f in fields
                    if f["name"] == "SELOPT" and f["rrn"] > 0
                    and f["value"].strip() == "5"), None)
        if sel:
            idx = sel["rrn"] - 1
            if 0 <= idx < len(self.sfl):
                self.ctx = self.sfl[idx]["PARTNO"]
                self.pgm, self.stack = "MOV100", "INQ100"
                return self._show_mov(self.ctx)
            self.msg = "No part on that line."
            return self._show_inq()

        posto = next((f["value"].strip() for f in fields
                      if f["name"] == "POSTO" and f["rrn"] == 0), "")

        if posto:
            self.sfl = self._page(anchor=posto)
            self.pageno = 1
            self.msg = f"Positioned at {posto}."
        elif aid == "ROLLUP":
            nxt = self._page(anchor=self._end(), gt=True)
            if not nxt:
                self.msg = "Already at the bottom of the file."
            else:
                self.sfl = nxt
                self.pageno += 1
                self.msg = f"Page {self.pageno}."
        elif aid == "ROLLDOWN":
            if self.pageno <= 1:
                self.msg = "Already at the top of the file."
            else:
                self.sfl = self._page(anchor=self._top(), backward=True)
                self.pageno -= 1
                self.msg = f"Page {self.pageno}."

        return self._show_inq()
