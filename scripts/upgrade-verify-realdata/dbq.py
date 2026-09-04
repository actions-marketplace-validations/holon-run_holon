import sqlite3, sys
db, sql = sys.argv[1], sys.argv[2]
params = sys.argv[3:]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(sql, [f"%{p}%" for p in params]).fetchall()
print(rows[0][0] if len(rows) == 1 and len(rows[0]) == 1 else repr(rows))
