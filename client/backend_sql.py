"""
The real backend: the terminal talks to your SQL Server and nothing else.

Every screen comes back from QSYS.EXFMT as two result sets — the 24 rendered
lines with their attribute plane, then the input map. The client never
decides what a screen looks like; it only draws what the host sent and
collects what the user typed.

Needs a driver. In order of how likely you already have one:

    pip install pyodbc        (Windows, with the ODBC driver SSMS installed)
    pip install pymssql
    pip install python-tds    (pure Python, no ODBC driver needed)
"""
RS = "\x1e"     # record separator
US = "\x1f"     # field separator


def _connect(server, database, user, password):
    errors = []

    try:
        import pyodbc
        for drv in ("ODBC Driver 18 for SQL Server",
                    "ODBC Driver 17 for SQL Server",
                    "SQL Server Native Client 11.0",
                    "SQL Server"):
            try:
                cs = f"DRIVER={{{drv}}};SERVER={server};DATABASE={database};"
                cs += (f"UID={user};PWD={password};" if user
                       else "Trusted_Connection=yes;")
                cs += "TrustServerCertificate=yes;"
                return pyodbc.connect(cs, autocommit=True), "pyodbc/" + drv
            except Exception as e:                       # try the next driver
                errors.append(f"pyodbc {drv}: {e}")
    except ImportError:
        errors.append("pyodbc not installed")

    try:
        import pymssql
        return pymssql.connect(server=server, database=database,
                               user=user, password=password), "pymssql"
    except ImportError:
        errors.append("pymssql not installed")
    except Exception as e:
        errors.append(f"pymssql: {e}")

    try:
        import pytds
        return pytds.connect(dsn=server, database=database,
                             user=user, password=password,
                             autocommit=True), "python-tds"
    except ImportError:
        errors.append("python-tds not installed")
    except Exception as e:
        errors.append(f"python-tds: {e}")

    raise SystemExit("Could not connect to SQL Server.\n  " + "\n  ".join(errors))


class SqlBackend:
    def __init__(self, server="localhost", database="AS400",
                 user=None, password=None):
        self.cn, self.driver = _connect(server, database, user, password)
        self.jobid = None

    # -- turning two result sets into a screen -----------------------------
    @staticmethod
    def _read_screen(cur):
        rows, attrs = [], []
        for r in cur.fetchall():
            rows.append(r[1] if r[1] is not None else "")
            attrs.append(r[2] if len(r) > 2 and r[2] is not None else "")

        inputs = []
        if cur.nextset():
            for r in cur.fetchall():
                inputs.append({"rrn": int(r[0]), "name": str(r[1]).strip(),
                               "lin": int(r[2]), "pos": int(r[3]),
                               "len": int(r[4])})
        return {"rows": rows, "attrs": attrs, "inputs": inputs}

    # -- the contract ------------------------------------------------------
    def open(self):
        cur = self.cn.cursor()
        cur.execute(
            "DECLARE @J INT; EXEC WARELIB.SIGNON @J OUTPUT; "
            "SELECT @J AS JOBID;")
        # SIGNON writes the screen first, then we ask for the job id
        screen = self._read_screen(cur)
        while cur.nextset():
            row = cur.fetchall()
            if row and len(row[0]) == 1:
                self.jobid = int(row[0][0])
        cur.close()

        if self.jobid is None:      # fall back: start the job explicitly
            cur = self.cn.cursor()
            cur.execute("DECLARE @J INT; EXEC QSYS.STRWSJOB 'INQ100', @J OUTPUT;"
                        " SELECT @J;")
            self.jobid = int(cur.fetchall()[0][0])
            cur.close()
        return screen

    def submit(self, aid, fields):
        payload = RS.join(
            f"{f['rrn']}{US}{f['name']}{US}{f['value']}" for f in fields)

        cur = self.cn.cursor()
        cur.execute("EXEC WARELIB.WSPGM_STR ?, ?, ?;",
                    (self.jobid, aid, payload))

        try:
            screen = self._read_screen(cur)
        except Exception:
            screen = None
        cur.close()

        cur = self.cn.cursor()
        cur.execute("SELECT WARELIB.JOB_ENDED(?);", (self.jobid,))
        ended = bool(cur.fetchall()[0][0])
        cur.close()

        if ended:
            self.close()
            return None
        return screen

    def close(self):
        try:
            if self.jobid is not None:
                cur = self.cn.cursor()
                cur.execute("EXEC QSYS.ENDWSJOB ?;", (self.jobid,))
                cur.close()
        except Exception:
            pass
