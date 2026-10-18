#!/usr/bin/env python3 -I
"""Load existing Shopify/Square credentials into the LOCAL Rust Rupert and run read-only syncs.
Credentials come from a 0600 env file and are never printed or logged. Prints counts only.

  ~/.config/rupert-core/live.env   (SHOPIFY_SHOP_DOMAIN, SHOPIFY_CLIENT_ID, SHOPIFY_CLIENT_SECRET,
                                    SQUARE_ACCESS_TOKEN, SQUARE_ENVIRONMENT)
Usage: python3 -I scripts/live-load.py [shopify] [square]      (default: whatever the file provides)"""
import json, os, secrets, stat, sys, time, urllib.error, urllib.request

DIR = os.environ.get("RUPERT_LIVE_DIR", os.path.expanduser("~/.config/rupert-core"))
BASE = os.environ.get("RUPERT_LIVE_BASE", "http://127.0.0.1:8798")
ENV = os.path.join(DIR, "live.env")
OWNER = os.path.join(DIR, "live-owner.json")

def die(m): print("error:", m); sys.exit(1)
if not os.path.exists(ENV): die(f"{ENV} not found (copy live.env.template and fill it in)")
if os.stat(ENV).st_mode & (stat.S_IRWXG | stat.S_IRWXO): die(f"{ENV} must be private: chmod 600 {ENV}")
env = {}
for line in open(ENV):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")

def call(method, path, body=None, tok=None):
    h = {"content-type": "application/json"}
    if tok: h["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(BASE + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try: x = urllib.request.urlopen(r, timeout=60); return x.status, json.loads(x.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}
    except urllib.error.URLError: die(f"cannot reach {BASE}; start scripts/run-live.sh first")

# local owner account (random password kept in a private file; this is not a production account)
if not os.path.exists(OWNER):
    acct = {"email": os.environ.get("RUPERT_LIVE_EMAIL", "owner@rupert.local"), "password": secrets.token_urlsafe(24)}
    s, r = call("POST", "/auth/signup", {**acct, "org_name": os.environ.get("RUPERT_LIVE_ORG", "Local live test"), "subdomain": os.environ.get("RUPERT_LIVE_SUBDOMAIN", "live-test")})
    if s != 201: die(f"signup failed ({s}): {r.get('error')}")
    fd = os.open(OWNER, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); open(fd, "w").write(json.dumps(acct))
acct = json.load(open(OWNER))
s, r = call("POST", "/auth/login", acct)
if s != 200: die(f"login failed ({s}): {r.get('error')}")
tok = r["session_token"]

want = sys.argv[1:] or [p for p, k in (("shopify", "SHOPIFY_CLIENT_SECRET"), ("square", "SQUARE_ACCESS_TOKEN")) if env.get(k)]
if not want: die("no credentials found in live.env for shopify or square")
if "shopify" in want:
    for k in ("SHOPIFY_SHOP_DOMAIN", "SHOPIFY_CLIENT_ID", "SHOPIFY_CLIENT_SECRET"):
        if not env.get(k): die(f"missing {k}")
    s, r = call("PUT", "/api/v1/connections/shopify", {"shop_domain": env["SHOPIFY_SHOP_DOMAIN"], "client_id": env["SHOPIFY_CLIENT_ID"], "client_secret": env["SHOPIFY_CLIENT_SECRET"]}, tok)
    if s != 200: die(f"shopify connection rejected ({s}): {r.get('error')}")
if "square" in want:
    if not env.get("SQUARE_ACCESS_TOKEN"): die("missing SQUARE_ACCESS_TOKEN")
    s, r = call("PUT", "/api/v1/connections/square", {"access_token": env["SQUARE_ACCESS_TOKEN"], "environment": env.get("SQUARE_ENVIRONMENT", "production")}, tok)
    if s != 200: die(f"square connection rejected ({s}): {r.get('error')}")

for src in want:
    runs0 = call("GET", "/api/v1/sync/runs", tok=tok)[1].get("data", [])
    done0 = len([x for x in runs0 if x["status"] != "running"])
    t0 = time.time(); s, r = call("POST", f"/api/v1/sync/{src}", tok=tok)
    if s != 202: die(f"{src} sync not started ({s}): {r.get('error')}")
    while True:
        runs = call("GET", "/api/v1/sync/runs", tok=tok)[1].get("data", [])
        if len([x for x in runs if x["status"] != "running"]) > done0: break
        if time.time() - t0 > 1800: die(f"{src} sync still running after 30 min")
        time.sleep(1)
    run = runs[0]
    print(f"{src}: {run['status']} in {time.time() - t0:.1f}s details={run.get('details')} error={run.get('error')}")
