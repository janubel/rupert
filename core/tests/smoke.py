#!/usr/bin/env python3
"""Black-box smoke test for milestone 2. Starts its own server on a temp data dir.
Usage: python3 -I tests/smoke.py [path-to-binary]"""
import json, os, subprocess, sys, tempfile, time, urllib.request, urllib.error

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../target/release/rupert-core")
PORT = 8791
BASE = f"http://127.0.0.1:{PORT}"
data = tempfile.mkdtemp(prefix="rupert-smoke-")
srv = subprocess.Popen([BIN], env=dict(os.environ, RUPERT_DATA=data, RUPERT_LISTEN=f"127.0.0.1:{PORT}",
                       RUPERT_COOKIE_SECURE="0", RUPERT_BASE_DOMAIN="rupert.test", RUPERT_SIGNUP="open"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
fails, total = [], 0

def call(method, path, body=None, tok=None, host=None, hdrs=None):
    h = {"content-type": "application/json"}
    if tok: h["Authorization"] = "Bearer " + tok
    if host: h["Host"] = host
    h.update(hdrs or {})
    req = urllib.request.Request(BASE + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        r = urllib.request.urlopen(req); return r.status, json.loads(r.read() or b"{}"), r.headers
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw), e.headers
        except Exception: return e.code, {}, e.headers

def check(name, got, want):
    global total
    total += 1
    if got != want: fails.append(f"{name}: got {got}, want {want}")

PW = "correct-horse-battery"
try:
    s, a, _ = call("POST", "/auth/signup", {"email": "a@x.test", "password": PW, "org_name": "Shop A", "subdomain": "shopa"})
    check("signup A", s, 201); A_SESS, A_T = a["session_token"], a["tenant_id"]
    s, b, _ = call("POST", "/auth/signup", {"email": "b@x.test", "password": PW, "org_name": "Shop B", "subdomain": "shopb"})
    check("signup B", s, 201); B_SESS = b["session_token"]
    check("dup email", call("POST", "/auth/signup", {"email": "A@x.test", "password": PW, "org_name": "X", "subdomain": "other"})[0], 409)
    check("dup subdomain", call("POST", "/auth/signup", {"email": "c@x.test", "password": PW, "org_name": "X", "subdomain": "shopa"})[0], 409)
    check("weak password", call("POST", "/auth/signup", {"email": "d@x.test", "password": "short", "org_name": "X", "subdomain": "dd"})[0], 400)
    check("signup rate limit (6th attempt)", call("POST", "/auth/signup", {"email": "e@x.test", "password": PW, "org_name": "X", "subdomain": "eee"})[0], 429)

    check("no auth", call("GET", "/api/v1/me")[0], 401)
    s, _, h = call("GET", "/api/v1/me", tok="garbage")
    check("garbage bearer", s, 401); check("www-authenticate", h.get("WWW-Authenticate"), "Bearer")
    s, me, h = call("GET", "/api/v1/me", tok=A_SESS, host="shopa.rupert.test")
    check("me via session+host", (s, me.get("role"), me.get("tenant_id")), (200, "owner", A_T)); check("no-store", h.get("Cache-Control"), "no-store")
    check("me session, no host (single membership)", call("GET", "/api/v1/me", tok=A_SESS)[0], 200)
    check("session on wrong host", call("GET", "/api/v1/me", tok=A_SESS, host="shopb.rupert.test")[0], 401)

    s, lg, _ = call("POST", "/auth/login", {"email": "a@x.test", "password": PW}); check("login ok", s, 200); OTHER_SESS = lg["session_token"]
    check("login wrong pw", call("POST", "/auth/login", {"email": "a@x.test", "password": "wrong-wrong-wrong"})[0], 401)
    check("login unknown", call("POST", "/auth/login", {"email": "nobody@x.test", "password": PW})[0], 401)

    check("bad scope", call("POST", "/api/v1/tokens", {"name": "x", "scopes": ["admin"]}, tok=A_SESS)[0], 400)
    s, t, _ = call("POST", "/api/v1/tokens", {"name": "rw", "scopes": ["inventory:read", "inventory:write"]}, tok=A_SESS)
    check("token create", (s, t["token"].startswith("rupert_"), len(t["token"])), (201, True, 50)); RW, RW_ID = t["token"], t["id"]
    s, t2, _ = call("POST", "/api/v1/tokens", {"name": "ro", "scopes": ["inventory:read"]}, tok=A_SESS); RO = t2["token"]
    check("token cannot mint tokens", call("POST", "/api/v1/tokens", {"name": "y", "scopes": ["inventory:read"]}, tok=RW)[0], 403)

    check("put item", call("POST", "/api/v1/item", {"sku": "S1", "name": "Widget", "qty": 10}, tok=RW)[0], 200)
    s, it, _ = call("GET", "/api/v1/item?sku=S1", tok=RO); check("read w/ ro token", (s, it.get("qty")), (200, 10))
    s, it, _ = call("POST", "/api/v1/adjust", {"sku": "S1", "delta": -3, "reason": "sale"}, tok=RW); check("adjust", (s, it.get("qty")), (200, 7))
    check("ro token cannot write", call("POST", "/api/v1/adjust", {"sku": "S1", "delta": 1, "reason": "x"}, tok=RO)[0], 403)
    check("adjust unknown sku", call("POST", "/api/v1/adjust", {"sku": "NOPE", "delta": 1, "reason": "x"}, tok=RW)[0], 404)
    check("token ignores Host header (tenant fixed)", call("GET", "/api/v1/item?sku=S1", tok=RO, host="shopb.rupert.test")[0], 200)
    check("tenant B cannot see A's item", call("GET", "/api/v1/item?sku=S1", tok=B_SESS)[0], 404)

    s, l, _ = call("GET", "/api/v1/tokens", tok=A_SESS); check("list tokens", (s, len(l["data"])), (200, 2))
    check("revoke", call("DELETE", f"/api/v1/tokens/{RW_ID}", tok=A_SESS)[0], 200)
    check("revoked token rejected immediately", call("GET", "/api/v1/item?sku=S1", tok=RW)[0], 401)
    check("B cannot revoke A's token", call("DELETE", f"/api/v1/tokens/{t2['id']}", tok=B_SESS)[0], 404)

    s, inv, _ = call("POST", "/api/v1/invites", {"email": "staff@x.test", "role": "staff"}, tok=A_SESS); check("invite staff", s, 201)
    check("cannot invite owner", call("POST", "/api/v1/invites", {"email": "o@x.test", "role": "owner"}, tok=A_SESS)[0], 400)
    s, acc, _ = call("POST", "/auth/invites/accept", {"token": inv["invite_token"], "password": PW}); check("accept invite", s, 201); ST = acc["session_token"]
    check("invite single-use", call("POST", "/auth/invites/accept", {"token": inv["invite_token"], "password": PW})[0], 404)
    check("staff can read", call("GET", "/api/v1/item?sku=S1", tok=ST, host="shopa.rupert.test")[0], 200)
    check("staff cannot adjust", call("POST", "/api/v1/adjust", {"sku": "S1", "delta": 1, "reason": "x"}, tok=ST, host="shopa.rupert.test")[0], 403)
    check("staff cannot mint tokens", call("POST", "/api/v1/tokens", {"name": "z", "scopes": ["inventory:read"]}, tok=ST, host="shopa.rupert.test")[0], 403)
    check("staff cannot invite", call("POST", "/api/v1/invites", {"email": "q@x.test", "role": "staff"}, tok=ST, host="shopa.rupert.test")[0], 403)

    # password change
    NEWPW = "a-brand-new-long-password"
    check("pw change: wrong current password", call("POST", "/api/v1/me/password", {"current_password": "not-the-password", "new_password": NEWPW}, tok=A_SESS)[0], 401)
    check("pw change: too short", call("POST", "/api/v1/me/password", {"current_password": PW, "new_password": "short"}, tok=A_SESS)[0], 400)
    check("pw change: must differ", call("POST", "/api/v1/me/password", {"current_password": PW, "new_password": PW}, tok=A_SESS)[0], 400)
    check("pw change: tokens cannot", call("POST", "/api/v1/me/password", {"current_password": PW, "new_password": NEWPW}, tok=RO)[0], 403)
    check("pw change: needs auth", call("POST", "/api/v1/me/password", {"current_password": PW, "new_password": NEWPW})[0], 401)
    check("pw change ok", call("POST", "/api/v1/me/password", {"current_password": PW, "new_password": NEWPW}, tok=A_SESS)[0], 200)
    check("pw change keeps this session", call("GET", "/api/v1/me", tok=A_SESS)[0], 200)
    check("pw change signs out other sessions", call("GET", "/api/v1/me", tok=OTHER_SESS)[0], 401)
    check("old password no longer works", call("POST", "/auth/login", {"email": "a@x.test", "password": PW})[0], 401)
    check("new password works", call("POST", "/auth/login", {"email": "a@x.test", "password": NEWPW})[0], 200)

    check("logout", call("POST", "/auth/logout", tok=ST)[0], 200)
    check("logged-out session rejected", call("GET", "/api/v1/me", tok=ST)[0], 401)

    codes = [call("POST", "/auth/login", {"email": "burst@x.test", "password": "wrong-wrong-wrong"})[0] for _ in range(12)]
    check("login email throttle", (codes[0], codes[-1]), (401, 429))
finally:
    srv.terminate(); srv.wait()

print(f"{total - len(fails)}/{total} passed")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
