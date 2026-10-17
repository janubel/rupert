#!/usr/bin/env python3
"""Operational behaviour: health endpoint, overdue detection, token-safe access log, graceful shutdown.
Usage: python3 -I tests/ops_smoke.py [path-to-binary]"""
import http.client, json, os, signal, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../target/release/rupert-core")
PORT = 8795
data = tempfile.mkdtemp(prefix="rupert-ops-")
errlog = os.path.join(data, "stderr.log")
fails, total = [], 0
def check(name, got, want):
    global total; total += 1
    if got != want: fails.append(f"{name}: got {got!r}, want {want!r}")

def start():
    f = open(errlog, "a")
    return subprocess.Popen([BIN], env=dict(os.environ, RUPERT_DATA=data, RUPERT_LISTEN=f"127.0.0.1:{PORT}", RUPERT_COOKIE_SECURE="0", RUPERT_BASE_DOMAIN="rupert.test",
        RUPERT_ACCESS_LOG="1", RUPERT_DEV="1", RUPERT_SCHEDULER_TICK_SECS="1", RUPERT_MASTER_KEY="A" * 43 + "=",
        RUPERT_SHOPIFY_BASE="http://127.0.0.1:1", RUPERT_GIT_REV="testrev"), stdout=subprocess.DEVNULL, stderr=f)

def call(method, path, body=None, tok=None):
    h = {"content-type": "application/json"}
    if tok: h["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try: x = urllib.request.urlopen(r, timeout=10); return x.status, json.loads(x.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

srv = start(); time.sleep(1)
try:
    PW = "correct-horse-battery"
    s, a = call("POST", "/auth/signup", {"email": "ops@x.test", "password": PW, "org_name": "Ops", "subdomain": "ops"}); SESS = a["session_token"]
    s, t = call("POST", "/api/v1/tokens", {"name": "watch", "scopes": ["inventory:read", "inventory:write", "sync:run"]}, tok=SESS); TOK = t["token"]; TID = a["tenant_id"]

    s, h = call("GET", "/api/v1/health", tok=TOK)
    check("health ok on a fresh tenant", (s, h["status"], h["version"] != "", h["git_rev"] not in ("", "unknown"), h["tenant"]["counts"]["orders"], h["tenant"]["db_bytes"]["tenant"] > 0, h["tenant"]["providers"]["shopify"]["overdue"]), (200, "ok", True, True, 0, True, None))
    check("health needs auth", call("GET", "/api/v1/health")[0], 401)
    check("process section", sorted(h["process"]), ["open_tenants", "sse_streams", "syncs_running"])

    # a schedule that can never succeed (upstream refused) must show as overdue/degraded
    check("store connection", call("PUT", "/api/v1/connections/shopify", {"shop_domain": "ops-shop.myshopify.com", "client_id": "c", "client_secret": "s"}, tok=SESS)[0], 200)
    check("set schedule", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_seconds": 2}, tok=SESS)[0], 200)
    st = call("GET", "/api/v1/health", tok=TOK)[1]
    check("a brand-new schedule is not overdue yet", (st["status"], st["tenant"]["providers"]["shopify"]["overdue"]), ("ok", False))
    t0 = time.time()
    while time.time() - t0 < 15:
        st = call("GET", "/api/v1/health", tok=TOK)[1]
        if st["status"] == "degraded": break
        time.sleep(0.5)
    check("overdue schedule degrades health", (st["status"], st["tenant"]["providers"]["shopify"]["overdue"], st["tenant"]["providers"]["shopify"]["last_status"]), ("degraded", True, "failed"))
    call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_minutes": None}, tok=SESS)

    # access log: JSON, route templates only
    marker = "rwh_" + "Z" * 43
    call("POST", f"/hooks/shopify/{marker}", {"x": 1})
    time.sleep(0.3)
    log = open(errlog).read()
    check("access log uses the route template", '"route":"/hooks/{provider}/{token}"' in log, True)
    check("secret URL token and credentials never logged", [x for x in (marker, TOK, SESS, "client_secret", "Authorization") if x in log], [])

    # graceful shutdown with an open SSE stream and WAL content
    call("POST", "/api/v1/item", {"sku": "W-1", "name": "Wal", "qty": 5}, tok=TOK)
    for i in range(20): call("POST", "/api/v1/adjust", {"sku": "W-1", "delta": -1, "reason": "x"}, tok=TOK)
    state = {"eof": False, "status": None}
    def reader():
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
        c.request("GET", "/api/v1/events", headers={"Authorization": "Bearer " + TOK}); r = c.getresponse(); state["status"] = r.status
        try:
            while r.readline(): pass
        except Exception: pass
        state["eof"] = True
    th = threading.Thread(target=reader, daemon=True); th.start(); time.sleep(0.6)
    wal = os.path.join(data, "tenants", f"{TID}.db-wal")
    before = os.path.getsize(wal) if os.path.exists(wal) else 0
    t0 = time.time(); srv.send_signal(signal.SIGTERM)
    try: rc = srv.wait(timeout=20)
    except subprocess.TimeoutExpired: rc = "timeout"
    took = time.time() - t0
    check("SIGTERM exits cleanly and promptly with a stream open", (rc, took < 8, state["status"]), (0, True, 200))
    th.join(3); check("open SSE stream is closed by the shutdown", state["eof"], True)
    after = os.path.getsize(wal) if os.path.exists(wal) else 0
    check("WAL folded into the database on stop", (before > 0, after), (True, 0))
    log = open(errlog).read()
    check("stop logged with checkpoint count", '"msg":"stopped"' in log and '"checkpointed_databases":' in log, True)

    # data survives the restart
    srv = start(); time.sleep(1)
    s, it = call("GET", "/api/v1/item?sku=W-1", tok=TOK)
    check("data intact after restart", (s, it.get("qty")), (200, -15))
    s, h = call("GET", "/api/v1/health", tok=TOK); check("healthy after restart", h["status"], "ok")
finally:
    try: srv.terminate(); srv.wait(timeout=10)
    except Exception: srv.kill()

print(f"{total - len(fails)}/{total} passed")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
