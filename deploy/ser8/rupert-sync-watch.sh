#!/usr/bin/env bash
# Run on the SER8 host (not inside the container). Exits non-zero when Rupert's newest successful sync is older
# than MAX_AGE_MIN minutes (default 45; syncs run every 15), or when the job service is not running.
# Why it lives outside the container: the in-app monitors run on the same job worker, so they cannot report
# that worker being down (it was down from 2026-10-02 to 2026-10-13 unnoticed). Read-only: it never restarts anything.
# Also fails when free disk on the database volume inside the container drops below MIN_FREE_MB (default 1024),
# or when the app's own readiness endpoint (READY_URL, default off) answers anything but 200.
set -euo pipefail

MAX_AGE_MIN="${MAX_AGE_MIN:-45}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
INSTANCE="${INSTANCE:-rupert}"
DB="${DB:-/opt/rupert/web/storage/production.sqlite3}"
READY_URL="${READY_URL:-}"

free_mb="$(incus exec "$INSTANCE" -- df -Pm "$(dirname "$DB")" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "$free_mb" ] && [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
  echo "LOW DISK: ${free_mb} MB free on the Rupert database volume (floor ${MIN_FREE_MB} MB)" >&2
  exit 1
fi

if [ -n "$READY_URL" ]; then
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$READY_URL" || true)"
  if [ "$code" != "200" ]; then
    echo "NOT READY: $READY_URL answered HTTP ${code:-none}" >&2
    exit 1
  fi
fi

jobs_state="$(incus exec "$INSTANCE" -- systemctl is-active rupert-jobs 2>/dev/null || true)"
latest="$(incus exec "$INSTANCE" -- sqlite3 -readonly "$DB" "SELECT max(startedAt) FROM SyncRun WHERE status = 'success'" 2>/dev/null || true)"

if [ -z "$latest" ]; then
  echo "STALE: no successful Rupert sync found (jobs service: ${jobs_state:-unknown})" >&2
  exit 1
fi

# startedAt is stored as UTC, e.g. "2026-10-14 00:45:00.249179"
age_min=$(( ( $(date -u +%s) - $(date -u -d "${latest%%.*} UTC" +%s) ) / 60 ))

if [ "$age_min" -gt "$MAX_AGE_MIN" ] || [ "$jobs_state" != "active" ]; then
  echo "STALE: last successful sync ${age_min} min ago at ${latest} UTC (limit ${MAX_AGE_MIN}); rupert-jobs is ${jobs_state:-unknown}" >&2
  exit 1
fi
echo "ok: last successful sync ${age_min} min ago at ${latest} UTC; rupert-jobs active"
