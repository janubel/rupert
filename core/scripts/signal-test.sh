#!/bin/sh
# CAUTION: restarts the rupert-core service and STOPS then STARTS the named container. Run on SER8 only on a test
# container or a container that is not serving traffic.
# usage: signal-test.sh <container> ; checks in-container signaling, service restart and graceful host stop.
# Background: docs/DEPLOYMENT-PLAN.md section 12 (AppArmor stacked-label signal denials).
# Counters are measured as deltas over this run (the journal keeps older runs).
C="${1:?container}"
ex() { incus exec "$C" -- sh -c "$1"; }
ip() { incus list "$C" -c 4 --format csv | cut -d" " -f1; }
cnt() { ex "journalctl -u rupert-core --no-pager -o cat 2>/dev/null | grep -c '$1'; true" | tail -1; }
T0=$(date '+%Y-%m-%d %H:%M:%S')
echo "[T1] a process can signal its own child (started via incus exec):"
ex 'sleep 60 & p=$!; if kill -TERM $p 2>/dev/null; then wait $p 2>/dev/null; echo "     PASS"; else echo "     FAIL (denied)"; kill -KILL $p 2>/dev/null; fi'
echo "[T2] systemctl restart rupert-core replaces the process cleanly:"
S0=$(cnt '"msg":"stopped"'); L0=$(cnt 'left-over process'); P0=$(cnt panicked)
BEFORE=$(ex 'systemctl show rupert-core -p MainPID --value')
timeout 90 incus exec "$C" -- systemctl restart rupert-core; RC=$?
sleep 4
AFTER=$(ex 'systemctl show rupert-core -p MainPID --value'); N=$(ex 'pgrep -c rupert-core')
HC=$(curl -s -m 4 http://$(ip):8798/healthz)
DS=$(( $(cnt '"msg":"stopped"') - S0 )); DL=$(( $(cnt 'left-over process') - L0 )); DP=$(( $(cnt panicked) - P0 ))
echo "     restart rc=$RC pid $BEFORE -> $AFTER, processes=$N, healthz=$HC, new graceful-stop lines=$DS, new left-over warnings=$DL, new panics=$DP"
if [ "$RC" = 0 ] && [ "$N" = 1 ] && [ "$BEFORE" != "$AFTER" ] && [ "$HC" = ok ] && [ "$DS" -ge 1 ] && [ "$DL" = 0 ] && [ "$DP" = 0 ]; then echo "     PASS"; else echo "     FAIL"; fi
echo "[T3] kernel signal denials for this container since the start of this run: $(journalctl -k --since "$T0" --no-pager 2>/dev/null | grep "profile=\"incus-${C}_" | grep -c 'operation="signal"')"
echo "[T4] graceful stop from the host (incus stop, 40 s cap), then start:"
ex 'mkdir -p /var/log/journal; systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null; journalctl --flush 2>/dev/null; true'
S=$(date +%s); timeout 60 incus stop "$C" --timeout 40; echo "     stop took $(( $(date +%s) - S )) s"
incus start "$C"; for i in $(seq 1 30); do curl -s -m 2 http://$(ip):8798/healthz 2>/dev/null | grep -q ok && break; sleep 2; done
echo "     after start: processes=$(ex 'pgrep -c rupert-core') healthz=$(curl -s -m 4 http://$(ip):8798/healthz)"
echo "     previous boot ended with a graceful stop line: $(ex "journalctl -b -1 -u rupert-core --no-pager -o cat 2>/dev/null | grep -c '\"msg\":\"stopped\"'") (needs persistent journal; 0 on the first run is expected)"
