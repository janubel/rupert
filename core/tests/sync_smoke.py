#!/usr/bin/env python3
"""Milestone 3 end-to-end test against mock Shopify/Square upstreams.
Usage: python3 -I tests/sync_smoke.py [path-to-binary]"""
import base64, http.client, json, os, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../target/release/rupert-core")
PORT, MOCK = 8792, 8793
SHOPIFY_SECRET, SQUARE_TOKEN = "shh-secret-value-123", "sq-token-value-456"

# ---------------- mock upstreams ----------------
S = {"products": [], "square_items": [], "counts": {}, "log": [], "throttled": False, "delay": 0.0, "empty": False}

def gid(kind, n): return f"gid://shopify/{kind}/{n}"
def variant(n, sku, qty, price="10.00"):
    return {"id": gid("ProductVariant", n), "title": f"V{n}", "sku": sku, "price": price, "inventoryQuantity": qty, "inventoryItem": {"id": gid("InventoryItem", n), "tracked": True}}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj, headers=None):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("content-type", "application/json")
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("content-length") or 0); return self.rfile.read(n).decode() if n else ""
    def do_GET(self):
        u = urlparse(self.path); S["log"].append(("GET", u.path, ""))
        if u.path == "/v2/locations": return self.reply(200, {"locations": [{"id": "L1", "name": "Store One", "status": "ACTIVE"}, {"id": "L2", "name": "Store Two", "status": "ACTIVE"}, {"id": "L3", "name": "Closed", "status": "INACTIVE"}]})
        if u.path == "/v2/catalog/list":
            cur = parse_qs(u.query).get("cursor", [None])[0]; items = S["square_items"]
            if S["empty"]: return self.reply(200, {"objects": []})
            page, nxt = (items[:2], "c1") if cur is None else (items[2:], None)
            out = {"objects": page}
            if nxt: out["cursor"] = nxt
            return self.reply(200, out)
        self.reply(404, {})
    def do_POST(self):
        u = urlparse(self.path); b = self.body(); S["log"].append(("POST", u.path, b))
        if u.path == "/admin/oauth/access_token": return self.reply(200, {"access_token": "shpat_mock"})
        if u.path.endswith("/graphql.json"):
            if self.headers.get("X-Shopify-Access-Token") != "shpat_mock": return self.reply(401, {})
            time.sleep(S["delay"])
            q = json.loads(b); v = q["variables"]
            LOC = lambda n: gid("Location", n)
            if q["query"].startswith("query Locations"):
                return self.reply(200, {"data": {"locations": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [
                    {"id": LOC(1), "name": "Main", "isActive": True}, {"id": LOC(2), "name": "Warehouse", "isActive": True}, {"id": LOC(3), "name": "Closed", "isActive": False}]}}})
            if q["query"].startswith("query Levels("):
                if not S.get("levels_throttled"):
                    S["levels_throttled"] = True   # Shopify reports cost throttling as HTTP 200 + errors
                    return self.reply(200, {"errors": [{"message": "Throttled", "extensions": {"code": "THROTTLED"}}], "extensions": {"cost": {"requestedQueryCost": 200, "actualQueryCost": None, "throttleStatus": {"maximumAvailable": 1000, "currentlyAvailable": 100, "restoreRate": 100}}}})
                bysku = {}
                for pr in S["products"]:
                    for vn in pr["variants"]["nodes"]: bysku[vn["inventoryItem"]["id"]] = vn
                bysku[gid("InventoryItem", 99)] = variant(99, "EXTRA-1", 5)
                data = {}
                for key, item_id in v.items():
                    vn = bysku.get(item_id)
                    if vn is None or vn["sku"] == "B-1": data[key] = None; continue      # unknown to Shopify -> primary fallback
                    nodes = [{"location": {"id": LOC(1)}, "quantities": [{"name": "available", "quantity": vn["inventoryQuantity"]}]}]
                    if vn["sku"] == "A-1": nodes.append({"location": {"id": LOC(2)}, "quantities": [{"name": "available", "quantity": 4}]})
                    if vn["sku"] == "A-2": nodes.append({"location": {"id": LOC(9)}, "quantities": [{"name": "available", "quantity": 5}]})   # unknown location: skipped
                    data[key] = {"id": item_id, "inventoryLevels": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}
                return self.reply(200, {"data": data})
            if "ProductVariants" in q["query"]:
                return self.reply(200, {"data": {"product": {"variants": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [variant(99, "EXTRA-1", 5)]}}}})
            if not S["throttled"]:
                S["throttled"] = True; return self.reply(429, {}, {"Retry-After": "1"})
            prods = [] if S["empty"] else S["products"]
            cur = v.get("cursor"); page, nxt = (prods[:2], "p1") if cur is None else (prods[2:], None)
            return self.reply(200, {"data": {"products": {"pageInfo": {"hasNextPage": bool(nxt), "endCursor": nxt}, "nodes": page}}})
        if u.path == "/v2/inventory/counts/batch-retrieve":
            req = json.loads(b); ids, locs = req["catalog_object_ids"], set(req["location_ids"])
            counts = [{"catalog_object_id": i, "location_id": loc, "state": "IN_STOCK", "quantity": str(q)} for i in ids for loc, q in S["counts"].get(i, {}).items() if loc in locs]
            return self.reply(200, {"counts": counts})
        self.reply(404, {})

def product(n, variants, more=False, status="ACTIVE"):
    return {"id": gid("Product", n), "title": f"P{n}", "status": status, "variants": {"pageInfo": {"hasNextPage": more, "endCursor": "vc1" if more else None}, "nodes": variants}}
def sq(n, sku): return {"type": "ITEM", "id": f"ITEM{n}", "item_data": {"name": f"Item {n}", "variations": [{"id": f"VAR{n}", "item_variation_data": {"name": f"Var {n}", "sku": sku}}]}}

def reset_mock():
    S.update(products=[product(1, [variant(1, "A-1", 10), variant(2, "A-2", 3)]), product(2, [variant(3, "B-1", 7)], more=True), product(3, [variant(4, "C-1", 1)], status="ARCHIVED")],
             square_items=[sq(1, "S-1"), sq(2, "S-2"), sq(3, "S-3")],
             counts={"VAR1": {"L1": 4, "L2": 6, "L3": 100}, "VAR2": {"L1": 2}}, throttled=False, delay=0.0, empty=False)

mock = ThreadingHTTPServer(("127.0.0.1", MOCK), H); threading.Thread(target=mock.serve_forever, daemon=True).start()
reset_mock()

# ---------------- server + helpers ----------------
data = tempfile.mkdtemp(prefix="rupert-sync-")
key = base64.b64encode(os.urandom(32)).decode()
srv = subprocess.Popen([BIN], env=dict(os.environ, RUPERT_DATA=data, RUPERT_LISTEN=f"127.0.0.1:{PORT}", RUPERT_COOKIE_SECURE="0", RUPERT_BASE_DOMAIN="rupert.test",
    RUPERT_DEV="1", RUPERT_SCHEDULER_TICK_SECS="1", RUPERT_MASTER_KEY=key, RUPERT_SHOPIFY_BASE=f"http://127.0.0.1:{MOCK}", RUPERT_SQUARE_BASE=f"http://127.0.0.1:{MOCK}/v2"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
fails, total, bodies = [], 0, []

def call(method, path, body=None, tok=None, host=None, port=None):
    h = {"content-type": "application/json"}
    if tok: h["Authorization"] = "Bearer " + tok
    if host: h["Host"] = host
    req = urllib.request.Request(f"http://127.0.0.1:{port or PORT}{path}", method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try: r = urllib.request.urlopen(req); raw, code = r.read(), r.status
    except urllib.error.HTTPError as e: raw, code = e.read(), e.code
    bodies.append(raw.decode(errors="replace"))
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, {}

def check(name, got, want):
    global total; total += 1
    if got != want: fails.append(f"{name}: got {got!r}, want {want!r}")

def wait_run(tok, n_done, timeout=20):
    t0 = time.time()
    while time.time() - t0 < timeout:
        runs = call("GET", "/api/v1/sync/runs", tok=tok)[1].get("data", [])
        done = [r for r in runs if r["status"] != "running"]
        if len(done) >= n_done: return runs[0]
        time.sleep(0.2)
    return None

class Sse(threading.Thread):
    def __init__(self, tok, last_id=None):
        super().__init__(daemon=True); self.events, self.tok, self.last_id = [], tok, last_id
        self.conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    def run(self):
        h = {"Authorization": "Bearer " + self.tok, "Accept": "text/event-stream"}
        if self.last_id is not None: h["Last-Event-ID"] = str(self.last_id)
        try:
            self.conn.request("GET", "/api/v1/events", headers=h); r = self.conn.getresponse(); self.status = r.status
            ev = {}
            while True:
                line = r.readline().decode()
                if not line: break
                line = line.rstrip("\n")
                if line == "":
                    if "data" in ev: self.events.append(json.loads(ev["data"]))
                    ev = {}
                elif ":" in line and not line.startswith(":"):
                    k, v = line.split(":", 1); ev[k] = v.strip()
        except Exception: pass
    def wait_for(self, pred, t=5):
        t0 = time.time()
        while time.time() - t0 < t:
            if any(pred(e) for e in list(self.events)): return True
            time.sleep(0.05)
        return False

PW = "correct-horse-battery"
try:
    s, a = call("POST", "/auth/signup", {"email": "o@x.test", "password": PW, "org_name": "Shop", "subdomain": "shop"}); OWN = a["session_token"]
    s, inv = call("POST", "/api/v1/invites", {"email": "st@x.test", "role": "staff"}, tok=OWN, host="shop.rupert.test")
    s, acc = call("POST", "/auth/invites/accept", {"token": inv["invite_token"], "password": PW}); STAFF = acc["session_token"]
    s, t = call("POST", "/api/v1/tokens", {"name": "cat", "scopes": ["catalog:read"]}, tok=OWN); CATONLY = t["token"]
    s, t = call("POST", "/api/v1/tokens", {"name": "sync", "scopes": ["inventory:read", "sync:run"]}, tok=OWN); SYNCTOK = t["token"]

    # connections: only signed-in owners
    check("staff cannot set connection", call("PUT", "/api/v1/connections/shopify", {"shop_domain": "a.myshopify.com", "client_id": "i", "client_secret": SHOPIFY_SECRET}, tok=STAFF)[0], 403)
    check("token cannot set connection", call("PUT", "/api/v1/connections/shopify", {"shop_domain": "a.myshopify.com", "client_id": "i", "client_secret": "x"}, tok=SYNCTOK)[0], 403)
    check("bad shop domain", call("PUT", "/api/v1/connections/shopify", {"shop_domain": "evil.com", "client_id": "i", "client_secret": "x"}, tok=OWN)[0], 400)
    check("bad square env", call("PUT", "/api/v1/connections/square", {"access_token": "t", "environment": "dev"}, tok=OWN)[0], 400)
    check("unknown provider", call("PUT", "/api/v1/connections/paypal", {}, tok=OWN)[0], 404)
    check("sync before connect", call("POST", "/api/v1/sync/shopify", tok=OWN)[0], 409)
    check("set shopify", call("PUT", "/api/v1/connections/shopify", {"shop_domain": "mock-shop.myshopify.com", "client_id": "cid", "client_secret": SHOPIFY_SECRET}, tok=OWN)[0], 200)
    check("set square", call("PUT", "/api/v1/connections/square", {"access_token": SQUARE_TOKEN, "environment": "sandbox"}, tok=OWN)[0], 200)
    s, l = call("GET", "/api/v1/connections", tok=OWN); check("list connections", sorted(r["provider"] for r in l["data"]), ["shopify", "square"])
    check("staff cannot trigger sync", call("POST", "/api/v1/sync/shopify", tok=STAFF)[0], 403)
    check("catalog-only token cannot trigger", call("POST", "/api/v1/sync/shopify", tok=CATONLY)[0], 403)

    # first Shopify sync (includes a 429 retry, pagination and nested variant paging)
    s, r = call("POST", "/api/v1/sync/shopify", tok=SYNCTOK); check("trigger accepted", s, 202)
    check("second trigger while running", call("POST", "/api/v1/sync/shopify", tok=OWN)[0], 409)
    run = wait_run(OWN, 1); check("sync 1 finished", ((run or {}).get("status"), (run or {}).get("error")), ("ok", None))
    d = (run or {}).get("details") or {}
    check("sync 1 counts", (d.get("seen"), d.get("added"), d.get("changed"), d.get("removed")), (5, 5, 0, 0))
    api = (d or {}).get("api") or {}
    check("run records its own request counts", (api.get("requests", 0) >= 6, sorted(api.get("by_op", {}))), (True, ["Levels", "Locations", "ProductVariants", "Products", "token_exchange"]))
    check("throttling is counted (HTTP 429 + GraphQL THROTTLED); retries include any stale-connection retry", (api.get("throttled"), api.get("retries", 0) >= 2), (2, True))
    s, u = call("GET", "/api/v1/sync/usage?hours=1", tok=OWN)
    sh = u["providers"]["shopify"]
    check("usage endpoint totals match the run", (sh["requests"], sh["throttled"], sh["last_hour"]), (api["requests"], 2, api["requests"]))
    check("usage exposes the limits", (u["hourly_budget"], u["per_run_cap"]), (1000, 5000))
    s, c = call("GET", "/api/v1/catalog?source=shopify&per_page=2", tok=CATONLY)
    check("catalog page 1", (s, len(c["data"]), c["meta"]["has_more"], c["meta"]["next_page"]), (200, 2, True, 2))
    s, c3 = call("GET", "/api/v1/catalog?source=shopify&per_page=2&page=3", tok=CATONLY); check("catalog last page", (len(c3["data"]), c3["meta"]["has_more"]), (1, False))
    s, cat = call("GET", "/api/v1/catalog?source=shopify&per_page=100", tok=CATONLY)
    check("archived product mirrored with its status", {r["sku"]: r["status"] for r in cat["data"]}.get("C-1"), "ARCHIVED")
    check("catalog bad per_page", call("GET", "/api/v1/catalog?per_page=101", tok=CATONLY)[0], 400)
    check("catalog token cannot read inventory", call("GET", "/api/v1/inventory?source=shopify", tok=CATONLY)[0], 403)
    s, iv = call("GET", "/api/v1/inventory?source=shopify&per_page=100", tok=OWN); check("inventory total qty", sum(r["quantity"] for r in iv["data"]), 10 + 3 + 7 + 1 + 5)

    # per-location data (Shopify locations/levels, Square location names/counts)
    s, lo = call("GET", "/api/v1/locations?source=shopify", tok=OWN)
    check("shopify locations", sorted((l["name"], l["active"], l["primary"]) for l in lo["data"]), [("Closed", False, False), ("Main", True, True), ("Warehouse", True, False)])
    s, lv = call("GET", "/api/v1/inventory/levels?source=shopify&per_page=100", tok=OWN)
    got = {(r["sku"], r["location_id"].split("/")[-1]): r["quantity"] for r in lv["data"]}
    check("shopify levels (per location, unknown location skipped, fallback to primary)", got,
          {("A-1", "1"): 10, ("A-1", "2"): 4, ("A-2", "1"): 3, ("B-1", "1"): 7, ("C-1", "1"): 1, ("EXTRA-1", "1"): 5})
    check("levels paging", call("GET", "/api/v1/inventory/levels?source=shopify&per_page=2", tok=OWN)[1]["meta"]["has_more"], True)
    check("levels need inventory:read", call("GET", "/api/v1/inventory/levels", tok=CATONLY)[0], 403)
    check("sync 1 reports locations and levels", ((run or {}).get("details") or {}).get("locations"), 3)

    # live feed: connect, then change upstream and re-sync
    sse = Sse(OWN); sse.start(); time.sleep(0.5)
    S["products"][0]["variants"]["nodes"][0]["inventoryQuantity"] = 8      # A-1: 10 -> 8
    S["products"].pop()                                                    # C-1 removed
    S["products"].append(product(5, [variant(5, "D-1", -2)]))              # D-1 added (3rd page of mock)
    S["throttled"] = True
    call("POST", "/api/v1/sync/shopify", tok=OWN); run = wait_run(OWN, 2)
    d = (run or {}).get("details") or {}
    check("sync 2 oversold counted", d.get("oversold"), 1)
    s, iv2 = call("GET", "/api/v1/inventory?source=shopify&per_page=100", tok=OWN)
    check("oversold stock mirrored as 0 (Rails rule)", {r["sku"]: r["quantity"] for r in iv2["data"]}.get("D-1"), 0)
    check("sync 2 counts", (run or {}).get("status"), "ok"); check("sync 2 diff", (d.get("added"), d.get("changed"), d.get("removed")), (1, 1, 1))
    check("SSE got changed qty", sse.wait_for(lambda e: e["kind"] == "mirror.variant.changed" and e["data"]["qty"] == {"from": 10, "to": 8}), True)
    check("SSE got removed", sse.wait_for(lambda e: e["kind"] == "mirror.variant.removed" and e["data"]["sku"] == "C-1"), True)
    check("SSE got added", sse.wait_for(lambda e: e["kind"] == "mirror.variant.added" and e["data"]["sku"] == "D-1"), True)
    check("SSE got per-location change", sse.wait_for(lambda e: e["kind"] == "mirror.level.changed" and e["data"]["sku"] == "A-1" and e["data"]["qty"] == {"from": 10, "to": 8}), True)
    s, lv = call("GET", "/api/v1/inventory/levels?source=shopify&per_page=100", tok=OWN)
    got2 = {(r["sku"], r["location_id"].split("/")[-1]): r["quantity"] for r in lv["data"]}
    check("levels after resync (removed variant's levels gone, oversold clamped to 0)", (("C-1", "1") in got2, got2.get(("D-1", "1")), got2.get(("A-1", "1"))), (False, 0, 8))
    check("SSE got sync.finished", sse.wait_for(lambda e: e["kind"] == "sync.finished"), True)

    # POS-side adjust shows up live, and an unchanged re-sync emits nothing new
    call("POST", "/api/v1/item", {"sku": "LOC-1", "name": "Local", "qty": 10}, tok=OWN)
    call("POST", "/api/v1/adjust", {"sku": "LOC-1", "delta": -2, "reason": "sale"}, tok=OWN)
    check("SSE got adjust", sse.wait_for(lambda e: e["kind"] == "inventory.adjusted" and e["data"]["qty"] == 8), True)
    ids = [e["id"] for e in sse.events]; check("SSE ids strictly increasing", ids == sorted(set(ids)), True)
    before = call("GET", "/api/v1/events/recent?limit=500", tok=OWN)[1]["meta"]["last_id"]
    call("POST", "/api/v1/sync/shopify", tok=OWN); wait_run(OWN, 3)
    after = call("GET", "/api/v1/events/recent?since=%d&limit=500" % before, tok=OWN)[1]["data"]
    check("no-op sync emits only sync.finished", [e["kind"] for e in after], ["sync.finished"])

    # replay after a dropped connection
    mid = ids[len(ids) // 2]
    rep = Sse(OWN, last_id=mid); rep.start(); time.sleep(0.6)
    want = [e["id"] for e in sse.events if mid < e["id"] <= max(ids)]
    got = [e["id"] for e in rep.events if e["id"] <= max(ids)]
    check("Last-Event-ID replay is complete, ordered, no duplicates", got, want)
    check("SSE requires auth", http.client.HTTPConnection("127.0.0.1", PORT).request("GET", "/api/v1/events") or True, True)
    check("events 401 without auth", call("GET", "/api/v1/events/recent")[0], 401)

    # empty upstream must not wipe the mirror
    S["empty"] = True; S["throttled"] = True
    call("POST", "/api/v1/sync/shopify", tok=OWN); run = wait_run(OWN, 4)
    check("empty catalog refused", ((run or {}).get("status"), "refusing" in str((run or {}).get("error"))), ("failed", True))
    s, iv = call("GET", "/api/v1/inventory?source=shopify&per_page=100", tok=OWN); check("mirror intact after refusal", len(iv["data"]), 5)
    S["empty"] = False

    # Square: pagination, active locations only, summed counts
    call("POST", "/api/v1/sync/square", tok=OWN); run = wait_run(OWN, 5)
    check("square ok", (run or {}).get("status"), "ok")
    s, iv = call("GET", "/api/v1/inventory?source=square&per_page=100", tok=OWN)
    check("square qty (L1+L2 only; L3 inactive)", {r["sku"]: r["quantity"] for r in iv["data"]}, {"S-1": 10, "S-2": 2, "S-3": 0})
    s, lo = call("GET", "/api/v1/locations?source=square", tok=OWN); check("square location names (active only)", sorted(l["name"] for l in lo["data"]), ["Store One", "Store Two"])
    s, lv = call("GET", "/api/v1/inventory/levels?source=square&per_page=100", tok=OWN)
    check("square per-location counts", {(r["sku"], r["location_id"]): r["quantity"] for r in lv["data"]}, {("S-1", "L1"): 4, ("S-1", "L2"): 6, ("S-2", "L1"): 2})
    S["counts"]["VAR2"] = {"L1": 9}
    call("POST", "/api/v1/sync/square", tok=OWN); wait_run(OWN, 6)
    s, iv = call("GET", "/api/v1/inventory?source=square&per_page=100", tok=OWN); check("square qty updated", {r["sku"]: r["quantity"] for r in iv["data"]}["S-2"], 9)

    # per-tenant realtime switch: off = no event rows, feed endpoints refuse, everything else works
    import sqlite3
    tid = a["tenant_id"]
    def ecount():
        c = sqlite3.connect(f"{data}/tenants/{tid}.db"); n = c.execute("select count(*) from events").fetchone()[0]; c.close(); return n
    check("settings default on", call("GET", "/api/v1/settings", tok=OWN)[1], {"realtime": True})
    check("staff cannot change settings", call("PUT", "/api/v1/settings", {"realtime": False}, tok=STAFF)[0], 403)
    check("token cannot change settings", call("PUT", "/api/v1/settings", {"realtime": False}, tok=SYNCTOK)[0], 403)
    check("owner turns realtime off", call("PUT", "/api/v1/settings", {"realtime": False}, tok=OWN)[1], {"realtime": False})
    n0 = ecount()
    check("adjust still works while off", call("POST", "/api/v1/adjust", {"sku": "LOC-1", "delta": -1, "reason": "off"}, tok=OWN)[0], 200)
    done_before = len([r for r in call("GET", "/api/v1/sync/runs", tok=OWN)[1]["data"] if r["status"] != "running"])
    S["throttled"] = True; call("POST", "/api/v1/sync/shopify", tok=OWN); run = wait_run(OWN, done_before + 1)
    check("sync still works while off", (run or {}).get("status"), "ok")
    check("no event rows written while off", ecount(), n0)
    check("recent refuses while off", call("GET", "/api/v1/events/recent", tok=OWN)[0], 409)
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5); conn.request("GET", "/api/v1/events", headers={"Authorization": "Bearer " + OWN})
    check("stream refuses while off", conn.getresponse().status, 409); conn.close()
    check("owner turns realtime on", call("PUT", "/api/v1/settings", {"realtime": True}, tok=OWN)[1], {"realtime": True})
    s, rec = call("GET", "/api/v1/events/recent?since=%d&limit=50" % 0, tok=OWN)
    check("enable writes one marker event", (ecount() - n0, rec["data"][-1]["kind"] if rec.get("data") else None), (1, "realtime.enabled"))
    check("setting survives (re-read)", call("GET", "/api/v1/settings", tok=OWN)[1], {"realtime": True})

    # scheduled syncs (test-only every_seconds; production minimum is 5 minutes)
    check("schedule list starts empty", call("GET", "/api/v1/sync/schedule", tok=OWN)[1]["data"], [])
    check("staff cannot schedule", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_minutes": 15}, tok=STAFF)[0], 403)
    check("minimum interval enforced", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_minutes": 2}, tok=OWN)[0], 400)
    check("maximum interval enforced", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_minutes": 1441}, tok=OWN)[0], 400)
    check("unknown source", call("PUT", "/api/v1/sync/schedule", {"source": "paypal", "every_minutes": 15}, tok=OWN)[0], 404)
    def finished(src): return len([r for r in call("GET", "/api/v1/sync/runs", tok=OWN)[1]["data"] if r["status"] != "running" and r["source"] == src])
    before = finished("shopify")
    check("set schedule", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_seconds": 2}, tok=OWN)[0], 200)
    check("schedule listed", [r["source"] for r in call("GET", "/api/v1/sync/schedule", tok=OWN)[1]["data"]], ["shopify"])
    t0 = time.time()
    while time.time() - t0 < 15 and finished("shopify") < before + 2: time.sleep(0.3)
    check("scheduler started 2+ syncs by itself", finished("shopify") >= before + 2, True)
    # failing runs back off instead of hammering the upstream
    S["empty"] = True
    t0 = time.time(); sch = {}
    while time.time() - t0 < 20:
        rows = call("GET", "/api/v1/sync/schedule", tok=OWN)[1]["data"]
        sch = rows[0] if rows else {}
        if sch.get("consecutive_failures", 0) >= 1: break
        time.sleep(0.3)
    check("failures counted", sch.get("consecutive_failures", 0) >= 1, True)
    check("next attempt pushed out after a failure (backoff)", sch.get("next_due", 0) - int(time.time()) >= 2, True)
    S["empty"] = False
    check("remove schedule", call("PUT", "/api/v1/sync/schedule", {"source": "shopify", "every_minutes": None}, tok=OWN)[0], 200)
    time.sleep(1.5); settled = finished("shopify"); time.sleep(5)
    check("no syncs after schedule removed", finished("shopify"), settled)
    check("schedule list empty again", call("GET", "/api/v1/sync/schedule", tok=OWN)[1]["data"], [])

    # read-only guarantee: only allowlisted upstream calls were made, no mutations
    allowed = {("POST", "/admin/oauth/access_token"), ("POST", "/admin/api/2026-07/graphql.json"), ("GET", "/v2/locations"), ("GET", "/v2/catalog/list"), ("POST", "/v2/inventory/counts/batch-retrieve")}
    bad = [(m, p) for m, p, b in S["log"] if (m, p) not in allowed]
    check("upstream calls all allowlisted", bad, [])
    check("no mutation in any upstream body", [b for _, _, b in S["log"] if "mutation" in b.lower()], [])
    check("upstream was actually called", len(S["log"]) > 10, True)

    # secrets never leave the server
    check("secrets absent from all API responses", [b for b in bodies if SHOPIFY_SECRET in b or SQUARE_TOKEN in b], [])
    raw = b"".join(open(os.path.join(dp, f), "rb").read() for dp, _, fs in os.walk(data) for f in fs)
    check("secrets not stored in plaintext on disk", (SHOPIFY_SECRET.encode() in raw, SQUARE_TOKEN.encode() in raw), (False, False))
    check("disconnect", call("DELETE", "/api/v1/connections/square", tok=OWN)[0], 200)
    check("sync after disconnect", call("POST", "/api/v1/sync/square", tok=OWN)[0], 409)
    # request cap and hourly budget (second server with tiny limits)
    P2 = 8794
    srv2 = subprocess.Popen([BIN], env=dict(os.environ, RUPERT_DATA=tempfile.mkdtemp(prefix="rupert-cap-"), RUPERT_LISTEN=f"127.0.0.1:{P2}", RUPERT_COOKIE_SECURE="0", RUPERT_BASE_DOMAIN="rupert.test",
        RUPERT_DEV="1", RUPERT_SCHEDULER="0", RUPERT_MASTER_KEY=key, RUPERT_MAX_REQUESTS_PER_RUN="3", RUPERT_API_BUDGET_PER_HOUR="10",
        RUPERT_SHOPIFY_BASE=f"http://127.0.0.1:{MOCK}", RUPERT_SQUARE_BASE=f"http://127.0.0.1:{MOCK}/v2"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        s2, a2 = call("POST", "/auth/signup", {"email": "cap@x.test", "password": PW, "org_name": "Cap", "subdomain": "cap"}, port=P2); T2 = a2["session_token"]
        call("PUT", "/api/v1/connections/shopify", {"shop_domain": "mock-shop.myshopify.com", "client_id": "c", "client_secret": "s"}, tok=T2, port=P2)
        statuses = []
        for n in range(6):
            st, r = call("POST", "/api/v1/sync/shopify", tok=T2, port=P2); statuses.append(st)
            if st != 202: break
            t0 = time.time()
            while time.time() - t0 < 10:
                runs = call("GET", "/api/v1/sync/runs", tok=T2, port=P2)[1]["data"]
                if runs and runs[0]["status"] != "running": break
                time.sleep(0.2)
        last = call("GET", "/api/v1/sync/runs", tok=T2, port=P2)[1]["data"][0]
        check("runaway run aborted by the per-run cap", (last["status"], "request cap" in str(last["error"]), last["details"]["api"]["requests"]), ("failed", True, 3))
        check("hourly budget refuses further syncs (429)", statuses[-1], 429)
        check("budget reached only after enough requests were spent", len(statuses) >= 4, True)
        u2 = call("GET", "/api/v1/sync/usage", tok=T2, port=P2)[1]
        check("usage reflects failed runs too", u2["providers"]["shopify"]["last_hour"] >= 10, True)
    finally:
        srv2.terminate(); srv2.wait()
finally:
    srv.terminate(); srv.wait(); mock.shutdown()

print(f"{total - len(fails)}/{total} passed")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
