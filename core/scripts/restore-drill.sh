#!/usr/bin/env bash
# Restore drill for rupert-core. Runs on the SER8 host as a user in incus-admin; leaves nothing behind.
# 1. takes a fresh backup in the live container and pulls it to the host (the host copy is what gets restored),
# 2. creates a scratch container, restores the backup into it and starts the REAL service from the restored data,
# 3. verifies: login with the owner password, row counts equal the manifest, sealed credentials decrypt with the
#    right master key (and are refused with a wrong one),
# 4. deletes the scratch container.
# Safety: the scratch service has the scheduler OFF and its Shopify/Square base URLs point at a closed local port, so
# it cannot reach the real stores. Secrets (master key, owner password) move container-to-container on the host and
# are never printed.
set -uo pipefail
exec </dev/null   # never let an inherited open stdin (for example from ssh) block the incus exec calls
SRC=rupert-core; SCR=rupert-restore-drill
IMG="${IMG:-$(incus image list --format csv -c f | head -1)}"
# the release directory whose binary is byte-identical to the one running in production
PROD_SHA=$(incus exec $SRC -- sha256sum /usr/local/bin/rupert-core | cut -d' ' -f1)
REL="${REL:-$(grep -l "^$PROD_SHA" "$HOME"/rupert-core-releases/*/SHA256SUMS 2>/dev/null | head -1 | xargs -r dirname)}"
[ -x "$REL/rupert-core" ] || { echo "no release directory matches the running binary ($PROD_SHA)" >&2; exit 1; }
DEST="$HOME/rupert-core-backups"
FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
step() { echo; echo "== $*"; }
cleanup() { incus delete "$SCR" --force >/dev/null 2>&1 || true; }
trap cleanup EXIT
scr() { incus exec "$SCR" -- "$@"; }

step "1. fresh backup in $SRC, copied to the host"
incus exec $SRC -- systemctl start rupert-core-backup.service || { fail "backup run failed"; exit 1; }
"$HOME/.local/bin/rupert-core-backup-pull" | tail -2
RUN=$(ls -d "$DEST"/20*Z | tail -1 | xargs basename)
[ -f "$DEST/$RUN/MANIFEST.json" ] && pass "host copy $RUN present ($(du -sh "$DEST/$RUN" | cut -f1))" || { fail "no host copy"; exit 1; }

step "2. scratch container + restore"
incus delete "$SCR" --force >/dev/null 2>&1 || true
incus launch "$IMG" "$SCR" -c limits.cpu=1 -c limits.memory=256MiB >/dev/null 2>&1 || { fail "cannot create scratch container"; exit 1; }
incus config set "$SCR" raw.apparmor='signal (send,receive) peer=@{profile_name}//&unconfined,'
for _ in $(seq 1 30); do scr sh -c 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"' && break; sleep 2; done
T0=$(date +%s)
incus file push "$REL/rupert-core" $SCR/usr/local/bin/rupert-core --mode 0755 >/dev/null
incus exec $SRC -- cat /usr/local/sbin/rupert-core-restore | incus file push - $SCR/usr/local/sbin/rupert-core-restore --mode 0755
incus exec $SRC -- cat /etc/systemd/system/rupert-core.service | incus file push - $SCR/etc/systemd/system/rupert-core.service --mode 0644
incus file push -r "$DEST/$RUN" $SCR/root/ >/dev/null
scr sh -c 'useradd --system --home-dir /var/lib/rupert-core --shell /usr/sbin/nologin rupertcore; install -d -m 0755 /etc/rupert-core'
# env: the live master key (copied container to container, never printed) + safe overrides
incus exec $SRC -- grep '^RUPERT_MASTER_KEY=' /etc/rupert-core/env | incus exec $SCR -- sh -c 'umask 077; cat > /etc/rupert-core/env'
scr sh -c 'umask 077; printf "RUPERT_DATA=/var/lib/rupert-core\nRUPERT_LISTEN=127.0.0.1:8798\nRUPERT_SCHEDULER=0\nRUPERT_DEV=1\nRUPERT_SHOPIFY_BASE=http://127.0.0.1:1\nRUPERT_SQUARE_BASE=http://127.0.0.1:1/v2\n" >> /etc/rupert-core/env'
incus exec $SRC -- cat /root/.config/rupert-core/live-owner.json | incus exec $SCR -- sh -c 'umask 077; mkdir -p /root/.config/rupert-core; cat > /root/.config/rupert-core/live-owner.json'
if scr sh -c "install -d -m 0700 /var/lib/rupert-core && rupert-core-restore /root/$RUN /var/lib/rupert-core && chown -R rupertcore:rupertcore /var/lib/rupert-core"; then pass "restore tool: checksums, integrity and row counts verified"; else fail "restore failed"; exit 1; fi
scr sh -c 'systemctl daemon-reload; systemctl start rupert-core'
for _ in $(seq 1 30); do scr curl -s -m 2 http://127.0.0.1:8798/healthz 2>/dev/null | grep -q ok && break; sleep 1; done
RTO=$(( $(date +%s) - T0 ))
scr curl -s -m 3 http://127.0.0.1:8798/healthz | grep -q ok && pass "service healthy from restored data (restore + start took ${RTO}s after the container was ready)" || { fail "service did not come up"; scr journalctl -u rupert-core --no-pager -n 5 -o cat | cut -c1-200; exit 1; }

step "3. verification against the manifest"
cat > "$HOME/.drill-verify.py" <<'PY'
import json, glob, sys, time, urllib.request, urllib.error
run = sys.argv[1]; wrong = len(sys.argv) > 2
B = "http://127.0.0.1:8798"
def call(m, p, b=None, t=None):
    h = {"content-type": "application/json"}
    if t: h["Authorization"] = "Bearer " + t
    r = urllib.request.Request(B + p, method=m, headers=h, data=json.dumps(b).encode() if b is not None else None)
    try: x = urllib.request.urlopen(r, timeout=30); return x.status, json.loads(x.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}
acct = json.load(open("/root/.config/rupert-core/live-owner.json"))
s, r = call("POST", "/auth/login", acct); tok = r.get("session_token")
print(("LOGIN", s))
if not wrong:
    man = json.load(open(f"/root/{run}/MANIFEST.json"))
    tenant = [e for e in man["files"] if e["db"].startswith("tenants/")][0]["tables"]
    s, h = call("GET", "/api/v1/health", t=tok); c = h["tenant"]["counts"]
    want = {"shopify_variants": tenant["shopify_variants"], "square_variations": tenant["square_variations"], "orders": tenant["orders"], "events": tenant["events"]}
    print(("COUNTS", c == want, c))
    s, conns = call("GET", "/api/v1/connections", t=tok); print(("CONNECTIONS", sorted(x["provider"] for x in conns.get("data", []))))
# a sync reads the sealed credentials first; with the base URL dead the only possible outcomes are
# 'could not be decrypted' (wrong key) or a network error (credentials decrypted, nothing sent anywhere real)
n0 = len([x for x in call("GET", "/api/v1/sync/runs", t=tok)[1].get("data", []) if x["status"] != "running"])
s, r = call("POST", "/api/v1/sync/shopify", t=tok); t0 = time.time()
while s == 202 and time.time() - t0 < 60:
    if len([x for x in call("GET", "/api/v1/sync/runs", t=tok)[1]["data"] if x["status"] != "running"]) > n0: break
    time.sleep(0.5)
run0 = call("GET", "/api/v1/sync/runs", t=tok)[1]["data"][0]
print(("SYNC", run0["status"], "decrypt-failed" if "decrypt" in str(run0.get("error")) else ("credentials-decrypted" if "network error" in str(run0.get("error")) else str(run0.get("error"))[:80])))
PY
incus file push "$HOME/.drill-verify.py" $SCR/root/verify.py >/dev/null; rm -f "$HOME/.drill-verify.py"
OUT=$(scr python3 -I /root/verify.py "$RUN")
echo "$OUT" | sed 's/^/     /'
echo "$OUT" | grep -q "('LOGIN', 200)" && pass "owner login works with the restored password hash" || fail "login"
echo "$OUT" | grep -q "('COUNTS', True" && pass "health counts equal the manifest (variants, variations, orders, events)" || fail "counts differ from the manifest"
echo "$OUT" | grep -q "credentials-decrypted" && pass "sealed Shopify credentials decrypt with the escrowed master key (no real request was possible)" || fail "credentials did not decrypt"

step "4. negative control: a wrong master key must NOT decrypt"
scr sh -c 'sed -i "s|^RUPERT_MASTER_KEY=.*|RUPERT_MASTER_KEY=$(head -c 32 /dev/urandom | base64)|" /etc/rupert-core/env; systemctl restart rupert-core'
for _ in $(seq 1 30); do scr curl -s -m 2 http://127.0.0.1:8798/healthz 2>/dev/null | grep -q ok && break; sleep 1; done
OUT2=$(scr python3 -I /root/verify.py "$RUN" wrong)
echo "$OUT2" | sed 's/^/     /'
echo "$OUT2" | grep -q "decrypt-failed" && pass "with a wrong key the stored credentials stay unreadable (key escrow matters)" || fail "wrong key was not rejected as expected"

step "5. cleanup"
cleanup; trap - EXIT
incus list "$SCR" --format csv | grep -q . && fail "scratch container still exists" || pass "scratch container deleted"
echo; [ "$FAILED" = 0 ] && echo "DRILL RESULT: PASS" || { echo "DRILL RESULT: FAIL"; exit 1; }
