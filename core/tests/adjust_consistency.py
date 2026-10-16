#!/usr/bin/env python3
"""Concurrent adjusts on one SKU must be exactly accounted for: final qty, `movements` rows and
`events` rows must all equal the number of 200 responses. Needs `oha` and a seeded dev data dir.
Usage: RUPERT_BIN=... python3 -I tests/adjust_consistency.py <seeded-data-dir-copy>"""
import base64, hashlib, json, os, sqlite3, subprocess, sys, time
data = sys.argv[1]; BIN = os.environ.get("RUPERT_BIN") or os.path.join(os.path.dirname(__file__), "../target/release/rupert-core")
T = 9
tok = "rupert_" + base64.urlsafe_b64encode(hashlib.sha256(f"rupert-dev-{T}".encode()).digest()).decode().rstrip("=")
db = os.path.join(data, "tenants", f"t{T}.db")
def q(sql):
    c = sqlite3.connect(db); r = c.execute(sql).fetchone()[0]; c.close(); return r
srv = subprocess.Popen([BIN], env=dict(os.environ, RUPERT_DATA=data, RUPERT_DEV="1"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
try:
    q0, m0, e0 = q("SELECT qty FROM inventory_items WHERE sku='SKU-77'"), q("SELECT count(*) FROM movements WHERE sku='SKU-77'"), q("SELECT count(*) FROM events WHERE kind='inventory.adjusted' AND key='SKU-77'")
    out = subprocess.run(["oha", "--no-tui", "-n", "20000", "-c", "64", "-m", "POST", "-H", "Authorization: Bearer " + tok, "-H", "content-type: application/json",
        "-d", '{"sku":"SKU-77","delta":-1,"reason":"consistency"}', "--output-format", "json", "http://127.0.0.1:8799/api/v1/adjust"], capture_output=True, text=True).stdout
    ok = json.loads(out)["statusCodeDistribution"].get("200", 0)
    time.sleep(0.5)
    q1, m1, e1 = q("SELECT qty FROM inventory_items WHERE sku='SKU-77'"), q("SELECT count(*) FROM movements WHERE sku='SKU-77'"), q("SELECT count(*) FROM events WHERE kind='inventory.adjusted' AND key='SKU-77'")
    ids_ok = q("SELECT count(*) = count(DISTINCT id) FROM events")
    got = (q0 - q1, m1 - m0, e1 - e0, ids_ok)
    print(f"ok_responses={ok} qty_drop={got[0]} movements={got[1]} events={got[2]} unique_event_ids={bool(got[3])}")
    sys.exit(0 if ok > 0 and got == (ok, ok, ok, 1) else 1)
finally:
    srv.terminate(); srv.wait()
