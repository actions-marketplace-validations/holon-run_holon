import json, sqlite3, sys
dbdir, marker, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
db = f"{dbdir}/runtime.sqlite"
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.row_factory = sqlite3.Row
def one(sql, *p):
    return con.execute(sql, p).fetchone()[0]
def has_table(name):
    return con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone() is not None
# v0.30.0 (schema 25) predates schema_migration_baselines; report empty there.
HAS_BASELINES = has_table("schema_migration_baselines")
snap = {
    "integrity": one("PRAGMA integrity_check"),
    "schema_revision": one("SELECT COALESCE(MAX(version),0) FROM schema_migrations"),
    "versions_over_25": one("SELECT COUNT(*) FROM schema_migrations WHERE version > 25"),
    "baseline_count": one("SELECT COUNT(*) FROM schema_migration_baselines") if HAS_BASELINES else 0,
    "baselines": [dict(r) for r in con.execute(
        "SELECT baseline_id, source_version, target_version, covered_versions_json, schema_fingerprint FROM schema_migration_baselines")] if HAS_BASELINES else [],
    "agents": [r[0] for r in con.execute("SELECT agent_id FROM agent_states ORDER BY agent_id")],
    "message_count": one("SELECT COUNT(*) FROM messages"),
    "brief_count": one("SELECT COUNT(*) FROM briefs"),
    "marker": marker,
    "marker_messages": one("SELECT COUNT(*) FROM messages WHERE payload_json LIKE ?", f"%{marker}%"),
    "marker_briefs": one("SELECT COUNT(*) FROM briefs WHERE payload_json LIKE ?", f"%{marker}%"),
    "unamemsgs": one("SELECT COUNT(*) FROM messages WHERE payload_json LIKE '%uname%'"),
    "msg_ids": [r[0] for r in con.execute("SELECT evidence_id FROM messages ORDER BY created_at")],
}
con.close()
with open(outfile, "w") as f:
    json.dump(snap, f, indent=1)
print(json.dumps({k: snap[k] for k in ("integrity", "schema_revision", "versions_over_25", "baseline_count", "message_count", "brief_count", "marker_messages", "marker_briefs", "unamemsgs")}))
