#!/usr/bin/env python3
"""Backup/restore tool tests (stdlib only; no server needed). Usage: python3 -I tests/backup_test.py"""
import gzip, json, os, shutil, sqlite3, subprocess, sys, tempfile, threading, time

DEPLOY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "deploy")
BACKUP, RESTORE = os.path.join(DEPLOY, "rupert-core-backup"), os.path.join(DEPLOY, "rupert-core-restore")
fails, total = [], 0
def check(name, got, want):
    global total; total += 1
    if got != want: fails.append(f"{name}: got {got!r}, want {want!r}")

def run(script, *args, **env):
    r = subprocess.run([sys.executable, "-I", script, *args], capture_output=True, text=True, env={**os.environ, **env})
    return r.returncode, r.stdout + r.stderr

tmp = tempfile.mkdtemp(prefix="backup-test-")
data, out = os.path.join(tmp, "data"), os.path.join(tmp, "backups")
os.makedirs(os.path.join(data, "tenants"))
def mkdb(path):
    c = sqlite3.connect(path); c.execute("PRAGMA journal_mode=WAL")
    c.execute("create table xs (n integer)"); c.execute("create table ys (n integer)"); c.execute("create table meta (k text primary key, v text)")
    c.execute("insert into meta values ('hello','world')"); c.commit(); return c
paths = [os.path.join(data, "central.db"), os.path.join(data, "tenants", "a.db"), os.path.join(data, "tenants", "b.db")]
for p_ in paths: mkdb(p_).close()
env = dict(RUPERT_DATA=data, RUPERT_BACKUP_DIR=out, RUPERT_BACKUP_KEEP="2")

# writers keep committing pairs (one row in xs and one in ys per transaction) while backups run:
# a transactionally consistent snapshot always has len(xs) == len(ys).
stop = threading.Event()
def writer(path):
    c = sqlite3.connect(path, timeout=30)   # its own connection: sqlite3 objects are tied to their thread
    i = 0
    while not stop.is_set():
        c.execute("insert into xs values (?)", (i,)); c.execute("insert into ys values (?)", (i,)); c.commit(); i += 1
    c.close()
ths = [threading.Thread(target=writer, args=(p_,), daemon=True) for p_ in paths]
for t in ths: t.start()
time.sleep(0.3)

rc, o = run(BACKUP, **env)
check("backup succeeds while databases are being written", rc, 0)
runs = sorted(d for d in os.listdir(out) if d.endswith("Z"))
check("one run directory + status.json", (len(runs), os.path.exists(os.path.join(out, "status.json"))), (1, True))
man = json.load(open(os.path.join(out, runs[0], "MANIFEST.json")))
check("manifest lists central + both tenants", sorted(e["db"] for e in man["files"]), ["central.db", "tenants/a.db", "tenants/b.db"])
check("backup files are private (0600) and the directory is 0700", ({oct(os.stat(os.path.join(out, runs[0], e["file"])).st_mode & 0o777) for e in man["files"]}, oct(os.stat(out).st_mode & 0o777)), ({"0o600"}, "0o700"))
check("no master key or env file is ever copied", [f for f in os.listdir(os.path.join(out, runs[0])) if "env" in f.lower() or "key" in f.lower()], [])

# prune: keep 2
for _ in range(3):
    time.sleep(1.1); rc, _ = run(BACKUP, **env); check("repeat backup", rc, 0)
runs = sorted(d for d in os.listdir(out) if d.endswith("Z"))
check("pruned to RUPERT_BACKUP_KEEP=2 newest", len(runs), 2)
check("status.json points at the newest run", json.load(open(os.path.join(out, "status.json")))["dir"], runs[-1])
stop.set(); [t.join() for t in ths]

# restore
latest = os.path.join(out, runs[-1]); target = os.path.join(tmp, "restored")
rc, o = run(RESTORE, latest, target)
check("restore succeeds", rc, 0)
for rel in ("central.db", "tenants/a.db", "tenants/b.db"):
    c = sqlite3.connect(os.path.join(target, rel))
    nx, ny = c.execute("select count(*) from xs").fetchone()[0], c.execute("select count(*) from ys").fetchone()[0]
    check(f"{rel}: snapshot is transactionally consistent (xs == ys) and has data", (nx == ny, nx > 0, c.execute("pragma integrity_check").fetchone()[0], c.execute("select v from meta where k='hello'").fetchone()[0]), (True, True, "ok", "world"))
    c.close()
check("restored files are private", {oct(os.stat(os.path.join(target, r)).st_mode & 0o777) for r in ("central.db", "tenants/a.db")}, {"0o600"})

# safety rails
rc, o = run(RESTORE, latest, target); check("refuses a non-empty target", (rc != 0, "non-empty" in o, os.path.exists(os.path.join(target, "central.db"))), (True, True, True))
bad = os.path.join(tmp, "tampered"); shutil.copytree(latest, bad)
gz = os.path.join(bad, "tenants", "a.db.gz"); b = bytearray(open(gz, "rb").read()); b[len(b) // 2] ^= 0xFF; open(gz, "wb").write(b)
rc, o = run(RESTORE, bad, os.path.join(tmp, "t1")); check("tampered file is rejected before restoring", (rc != 0, "checksum mismatch" in o, os.path.exists(os.path.join(tmp, "t1"))), (True, True, False))
bad2 = os.path.join(tmp, "wrongcounts"); shutil.copytree(latest, bad2)
m = json.load(open(os.path.join(bad2, "MANIFEST.json"))); m["files"][0]["tables"]["xs"] += 1; json.dump(m, open(os.path.join(bad2, "MANIFEST.json"), "w"))
rc, o = run(RESTORE, bad2, os.path.join(tmp, "t2")); check("row-count mismatch vs manifest is rejected and cleaned up", (rc != 0, "row counts differ" in o, os.path.exists(os.path.join(tmp, "t2"))), (True, True, False))
bad3 = os.path.join(tmp, "missing"); shutil.copytree(latest, bad3); os.remove(os.path.join(bad3, "central.db.gz"))
rc, o = run(RESTORE, bad3, os.path.join(tmp, "t3")); check("missing file is rejected", (rc != 0, "missing file" in o), (True, True))

# failure leaves earlier backups alone and no partial directory
before = sorted(os.listdir(out))
open(os.path.join(data, "tenants", "corrupt.db"), "wb").write(b"this is not a sqlite database" * 50)
time.sleep(1.1); rc, o = run(BACKUP, **env)
check("a corrupt tenant database fails the run", (rc != 0, "backup-failed" in o), (True, True))
check("failed run leaves no .partial dir and earlier backups untouched", (sorted(os.listdir(out)), [d for d in os.listdir(out) if d.startswith(".partial")]), (before, []))
os.remove(os.path.join(data, "tenants", "corrupt.db"))
shutil.move(os.path.join(data, "central.db"), os.path.join(tmp, "central.gone"))
rc, o = run(BACKUP, **env); check("missing central.db fails clearly", (rc != 0, "no central.db" in o), (True, True))

shutil.rmtree(tmp, ignore_errors=True)
print(f"{total - len(fails)}/{total} passed")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
