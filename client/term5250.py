#!/usr/bin/env python3
"""
A 5250 terminal.

It draws a 24x80 screen, lets you type only where the DDS says you may, and
sends the whole buffer back when you press an AID key. That is the entire
contract of a block-mode terminal: while you are typing, the host knows
nothing about it.

    python term5250.py                 offline, against the local model
    python term5250.py --sql           against your SQL Server
    python term5250.py --sql --server localhost --database AS400

Keys
    Enter        send
    Tab / BTab   next / previous input field
    PgDn / PgUp  roll up / roll down
    F3           exit
    F12          back out of a drill-down
    Esc          quit without telling the host
"""
import argparse
import os
import sys

ESC = "\x1b"
HOME = f"{ESC}[H"
CLEAR = f"{ESC}[2J"
HIDE = f"{ESC}[?25l"
SHOW = f"{ESC}[?25h"
RESET = f"{ESC}[0m"

GREEN = f"{ESC}[38;5;41m"      # normal phosphor
BRIGHT = f"{ESC}[38;5;120m"    # DSPATR(HI)
DIM = f"{ESC}[38;5;29m"        # chrome
UNDER = f"{ESC}[4m"
NOUNDER = f"{ESC}[24m"


# ---------------------------------------------------------------------------
# Keyboard
# ---------------------------------------------------------------------------

class Keys:
    """Portable raw key reader. Returns a name, or a single character."""

    def __init__(self):
        self.win = os.name == "nt"
        self._fd = None
        self._old = None

    def __enter__(self):
        if not self.win:
            import termios, tty
            self._fd = sys.stdin.fileno()
            self._old = termios.tcgetattr(self._fd)
            tty.setraw(self._fd)
        return self

    def __exit__(self, *a):
        if not self.win and self._old is not None:
            import termios
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old)

    # -- Windows ----------------------------------------------------------
    _WIN_EXT = {
        ";": "F1", "<": "F2", "=": "F3", ">": "F4", "?": "F5", "@": "F6",
        "A": "F7", "B": "F8", "C": "F9", "D": "F10",
        "\x85": "F11", "\x86": "F12",
        "H": "UP", "P": "DOWN", "K": "LEFT", "M": "RIGHT",
        "I": "PGUP", "Q": "PGDN", "G": "HOME", "O": "END", "S": "DELETE",
    }

    def _read_win(self):
        import msvcrt
        ch = msvcrt.getwch()
        if ch in ("\x00", "\xe0"):
            return self._WIN_EXT.get(msvcrt.getwch(), "UNKNOWN")
        if ch == "\r":
            return "ENTER"
        if ch == "\t":
            return "TAB"
        if ch == "\x1b":
            return "ESC"
        if ch in ("\x08", "\x7f"):
            return "BACKSPACE"
        return ch

    # -- POSIX ------------------------------------------------------------
    _CSI = {
        "A": "UP", "B": "DOWN", "C": "RIGHT", "D": "LEFT",
        "H": "HOME", "F": "END", "Z": "BTAB",
    }
    _TILDE = {"5": "PGUP", "6": "PGDN", "3": "DELETE", "1": "HOME", "4": "END"}
    _SS3 = {"P": "F1", "Q": "F2", "R": "F3", "S": "F4"}
    _CSI_FN = {"15": "F5", "17": "F6", "18": "F7", "19": "F8",
               "20": "F9", "21": "F10", "23": "F11", "24": "F12"}

    def _read_posix(self):
        c = sys.stdin.read(1)
        if c == "\r" or c == "\n":
            return "ENTER"
        if c == "\t":
            return "TAB"
        if c in ("\x7f", "\x08"):
            return "BACKSPACE"
        if c != ESC:
            return c

        # escape sequence — read the rest
        seq = sys.stdin.read(1)
        if seq == "O":
            return self._SS3.get(sys.stdin.read(1), "UNKNOWN")
        if seq != "[":
            return "ESC"

        buf = ""
        while True:
            ch = sys.stdin.read(1)
            buf += ch
            if ch.isalpha() or ch == "~":
                break
            if len(buf) > 8:
                return "UNKNOWN"

        if buf.endswith("~"):
            num = buf[:-1].split(";")[0]
            return self._CSI_FN.get(num) or self._TILDE.get(num, "UNKNOWN")
        return self._CSI.get(buf[-1], "UNKNOWN")

    def read(self):
        return self._read_win() if self.win else self._read_posix()


# ---------------------------------------------------------------------------
# The terminal
# ---------------------------------------------------------------------------

class Terminal:
    def __init__(self, backend, out=sys.stdout):
        self.be = backend
        self.out = out
        self.screen = None
        self.fields = []        # [{name, rrn, lin, pos, len, value}]
        self.fx = 0             # which field the cursor is in
        self.off = 0            # offset within that field
        self.status = ""

    # -- screen handling ---------------------------------------------------
    def load(self, screen):
        self.screen = screen
        self.fields = []
        for f in screen.get("inputs", []):
            g = dict(f)
            lin, pos, ln = g["lin"], g["pos"], g["len"]
            # seed from what is on the screen, so the field shows its value
            row = screen["rows"][lin - 1] if lin - 1 < len(screen["rows"]) else ""
            g["value"] = (row + " " * 80)[pos - 1:pos - 1 + ln]
            self.fields.append(g)
        self.fx = 0
        self.off = 0

    def _compose(self):
        """The screen plus whatever the user has typed since it arrived."""
        rows = [list((r + " " * 80)[:80]) for r in self.screen["rows"]]
        for f in self.fields:
            v = (f["value"] + " " * f["len"])[:f["len"]]
            for i, ch in enumerate(v):
                c = f["pos"] - 1 + i
                if 0 <= c < 80 and 0 < f["lin"] <= len(rows):
                    rows[f["lin"] - 1][c] = ch
        return ["".join(r) for r in rows]

    def draw(self):
        rows = self._compose()
        attrs = self.screen.get("attrs") or [" " * 80] * len(rows)
        infield = {(f["lin"], f["pos"] - 1 + i)
                   for f in self.fields for i in range(f["len"])}

        w = [HOME]
        for r, line in enumerate(rows, start=1):
            a = (attrs[r - 1] + " " * 80)[:80] if r - 1 < len(attrs) else " " * 80
            w.append(f"{ESC}[{r};1H")
            cur = None
            for c, ch in enumerate(line):
                want = BRIGHT if a[c] == "H" else GREEN
                u = (r, c) in infield
                style = want + (UNDER if u else NOUNDER)
                if style != cur:
                    w.append(style)
                    cur = style
                w.append(ch)
            w.append(f"{RESET}{ESC}[K")

        w.append(f"{ESC}[25;1H{DIM}")
        w.append(self.status.ljust(80)[:80])
        w.append(RESET)

        if self.fields:
            f = self.fields[self.fx]
            w.append(f"{ESC}[{f['lin']};{f['pos'] + self.off}H")
        self.out.write("".join(w))
        self.out.flush()

    # -- editing -----------------------------------------------------------
    def _field(self):
        return self.fields[self.fx] if self.fields else None

    def type(self, ch):
        f = self._field()
        if not f or self.off >= f["len"]:
            return
        v = list((f["value"] + " " * f["len"])[:f["len"]])
        v[self.off] = ch              # overwrite, as a 5250 does
        f["value"] = "".join(v)
        if self.off < f["len"] - 1:
            self.off += 1
        elif self.fx < len(self.fields) - 1:
            self.fx, self.off = self.fx + 1, 0

    def backspace(self):
        f = self._field()
        if not f:
            return
        if self.off > 0:
            self.off -= 1
        v = list((f["value"] + " " * f["len"])[:f["len"]])
        v[self.off] = " "
        f["value"] = "".join(v)

    def move(self, key):
        f = self._field()
        if not f:
            return
        if key == "LEFT":
            if self.off > 0:
                self.off -= 1
            elif self.fx > 0:
                self.fx -= 1
                self.off = self.fields[self.fx]["len"] - 1
        elif key == "RIGHT":
            if self.off < f["len"] - 1:
                self.off += 1
            elif self.fx < len(self.fields) - 1:
                self.fx, self.off = self.fx + 1, 0
        elif key in ("TAB", "DOWN"):
            self.fx = (self.fx + 1) % len(self.fields)
            self.off = 0
        elif key in ("BTAB", "UP"):
            self.fx = (self.fx - 1) % len(self.fields)
            self.off = 0
        elif key == "HOME":
            self.off = 0
        elif key == "END":
            self.off = f["len"] - 1

    # -- the AID keys ------------------------------------------------------
    AID = {"ENTER": "ENTER", "F3": "F3", "F12": "F12",
           "PGDN": "ROLLUP", "PGUP": "ROLLDOWN",
           "F5": "F5", "F6": "F6"}

    def submit(self, aid):
        payload = [{"rrn": f.get("rrn", 0), "name": f["name"],
                    "value": f["value"].rstrip()} for f in self.fields]
        screen = self.be.submit(aid, payload)
        if screen is None:
            return False
        self.load(screen)
        return True

    # -- the loop ----------------------------------------------------------
    def run(self, keysource=None):
        self.load(self.be.open())
        self.status = ("  Enter=send   Tab=next field   PgDn/PgUp=roll   "
                       "F3=exit   F12=back")
        self.out.write(HIDE + CLEAR)
        try:
            self.draw()
            while True:
                key = keysource()
                if key == "ESC":
                    break
                if key in self.AID:
                    if not self.submit(self.AID[key]):
                        break
                elif key == "BACKSPACE":
                    self.backspace()
                elif key in ("LEFT", "RIGHT", "UP", "DOWN", "TAB", "BTAB",
                             "HOME", "END"):
                    self.move(key)
                elif len(key) == 1 and key.isprintable():
                    self.type(key)
                self.draw()
        finally:
            self.out.write(f"{ESC}[25;1H{RESET}{SHOW}\n")
            self.out.flush()


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="A 5250 terminal.")
    ap.add_argument("--sql", action="store_true",
                    help="talk to SQL Server instead of the offline model")
    ap.add_argument("--server", default="localhost")
    ap.add_argument("--database", default="AS400")
    ap.add_argument("--user"), ap.add_argument("--password")
    args = ap.parse_args()

    if args.sql:
        from backend_sql import SqlBackend
        be = SqlBackend(args.server, args.database, args.user, args.password)
    else:
        from backend_demo import DemoBackend
        be = DemoBackend()

    term = Terminal(be)
    with Keys() as k:
        term.run(k.read)


if __name__ == "__main__":
    main()
