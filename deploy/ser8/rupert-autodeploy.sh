#!/usr/bin/env bash
# Auto-deploy origin/main to /opt/rupert when app CI is green. Fast-forward only,
# clean checkout only, DB backup first, health check, code rollback on failure.
# A commit that failed to deploy is remembered and not retried until main moves.
# DRY_RUN=1 reports what it would do without changing anything.
# The RUPERT_AUTODEPLOY_* variables exist for the tests in deploy/ser8/tests.
set -uo pipefail
# Normal umask: git checkout and bundle install run as root here, and the app
# runs as the rupert user, so code and gems must stay world-readable. (umask
# 077 made Gemfile.lock and a new gem unreadable and took the site down on
# 2026-10-21.) Backups get a private umask of their own below.
umask 022
APP=${RUPERT_AUTODEPLOY_APP:-/opt/rupert}
REPO=techmore/rupert
HOST=rupert.stoverparc.org
BACKUPS=${RUPERT_AUTODEPLOY_BACKUPS:-/var/backups/rupert-autodeploy}
STATE=${RUPERT_AUTODEPLOY_STATE:-/var/lib/rupert-autodeploy}
LOCK=${RUPERT_AUTODEPLOY_LOCK:-/run/rupert-autodeploy.lock}
ENV_FILE=${RUPERT_AUTODEPLOY_ENV_FILE:-/etc/rupert.env}
# Rupert (System → Updates) talks to this script through files only. It reads
# status.json and last-deploy.json from $STATE (root-owned, world-readable), and
# the app user owns $INBOX, where `manual` means "install only when asked" and
# touching `install-requested` asks for an install now (and overrides a
# failed-sha). Only the presence and mtime of those two files are read; nothing
# in $INBOX is ever opened, written or run by root.
INBOX=${RUPERT_AUTODEPLOY_INBOX:-$APP/web/storage/autodeploy}
export RAILS_ENV=production PATH=${RUPERT_AUTODEPLOY_PATH:-/opt/rbenv/versions/4.0.6/bin:/usr/local/bin:/usr/bin:/bin}
log() { echo "autodeploy: $*"; }

# write_json FILE STATE MESSAGE: atomic, readable by the app user. No-op on a dry run.
write_json() {
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  mkdir -p "$STATE" && chmod 755 "$STATE"
  python3 - "$STATE/$1" "$2" "$3" "${CUR:-}" "${NEW:-}" "$mode" "$requested" <<'PY' || log "could not write $1"
import datetime, json, os, sys
path, state, message, current, target, mode, requested = sys.argv[1:]
body = {'state': state, 'message': message, 'current': current, 'target': target, 'mode': mode,
        'install_requested': requested == '1',
        'at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}
with open(path + '.tmp', 'w') as f:
    json.dump(body, f)
os.chmod(path + '.tmp', 0o644)
os.replace(path + '.tmp', path)
PY
}
# report STATE MESSAGE: log it and tell the app.
report() { log "$2"; write_json status.json "$1" "$2"; }
# The request was acted on (installed, failed or nothing to install): forget it.
handle_request() {
  [ "$requested" = 1 ] && [ "${DRY_RUN:-0}" != 1 ] && { mkdir -p "$STATE"; echo "$requested_at" > "$STATE/request-handled"; }
  requested=0
}

exec 9>"$LOCK"
flock -n 9 || { log "another deploy is running"; exit 0; }

mode=automatic; [ -e "$INBOX/manual" ] && mode=manual
requested_at=$(stat -c %Y "$INBOX/install-requested" 2>/dev/null) || requested_at=0
handled_at=$(cat "$STATE/request-handled" 2>/dev/null); [[ $handled_at =~ ^[0-9]+$ ]] || handled_at=0
requested=0; [ "$requested_at" -gt "$handled_at" ] && requested=1

cd "$APP" || exit 1
if [ -n "$(git status --porcelain)" ]; then report blocked "checkout is dirty, skipping"; exit 0; fi
git fetch -q origin main || { report blocked "fetch failed"; exit 0; }
CUR=$(git rev-parse HEAD); NEW=$(git rev-parse origin/main)
[ "$CUR" = "$NEW" ] && { handle_request; report up_to_date "up to date at ${CUR:0:8}"; exit 0; }
git merge-base --is-ancestor "$CUR" "$NEW" || { report blocked "origin/main is not a fast-forward of ${CUR:0:8}, skipping"; exit 0; }
if [ "$requested" = 0 ] && [ "$(cat "$STATE/failed-sha" 2>/dev/null)" = "$NEW" ]; then
  report failed "${NEW:0:8} already failed to deploy, waiting for a newer commit (rm $STATE/failed-sha or request an install to retry)"; exit 0
fi

# The `CI (sqlite3)` job must be green. Re-runs leave the earlier check runs in
# the list, so only the most recent run counts.
ci=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/commits/$NEW/check-runs?per_page=100" | python3 -c '
import json, sys
latest = {}
for r in json.load(sys.stdin)["check_runs"]:
    if r["name"] == "CI (sqlite3)" and r["id"] > latest.get(r["name"], {"id": -1})["id"]:
        latest[r["name"]] = r
done = [r["conclusion"] for r in latest.values()]
if any(c in ("failure", "cancelled", "timed_out") for c in done): print("red")
elif len(latest) == 1 and all(c == "success" for c in done): print("green")
else: print("pending")') || ci=unknown
case "$ci" in
  green) ;;
  red) report ci_failed "CI for ${NEW:0:8} is red, not deploying"; exit 0 ;;
  *) report waiting_ci "CI for ${NEW:0:8} is $ci, not deploying yet"; exit 0 ;;
esac

migrations=$(git diff --name-only --diff-filter=A "$CUR" "$NEW" -- web/db/migrate | wc -l)
if [ "$mode" = manual ] && [ "$requested" = 0 ]; then
  report ready "${NEW:0:8} is ready to install ($migrations new migration(s)); manual mode waits for an install request"; exit 0
fi
log "deploying ${CUR:0:8} -> ${NEW:0:8} ($migrations new migration(s))"
[ "${DRY_RUN:-0}" = 1 ] && { log "dry run, stopping"; exit 0; }
# Recorded before the attempt so a failure is not retried by the same request.
handle_request
write_json status.json deploying "installing ${NEW:0:8} ($migrations new migration(s))"

mkdir -p "$BACKUPS" "$STATE"; chmod 700 "$BACKUPS"; chmod 755 "$STATE"
backup="$BACKUPS/production-$(date +%Y%m%d-%H%M%S)-${CUR:0:8}.sqlite3"
( umask 077; sqlite3 web/storage/production.sqlite3 ".backup $backup" ) || { report failed "backup failed, aborting"; exit 1; }
ls -1t "$BACKUPS"/*.sqlite3 | tail -n +6 | xargs -r rm -f

health() {
  for _ in $(seq 1 15); do
    [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' localhost:3000/up)" = 200 ] \
      && systemctl is-active --quiet rupert-web rupert-jobs && return 0
    sleep 2
  done; return 1
}
# The build runs as root; hand anything it wrote back to the app user.
fix_owner() { chown -R rupert:rupert web/storage web/public web/tmp web/log 2>/dev/null; return 0; }
rails_env() { set -a && . "$ENV_FILE" && set +a; }
build() {
  ( cd "$APP/web" && rails_env && bundle install --quiet && bundle exec rails db:migrate && bundle exec rails assets:precompile >/dev/null )
}

git checkout -q --detach "$NEW" && build && fix_owner && systemctl restart rupert-web rupert-jobs && health
if [ $? -ne 0 ]; then
  echo "$NEW" > "$STATE/failed-sha"
  if [ "$migrations" -gt 0 ]; then
    failure="${NEW:0:8} failed; $migrations migration(s) may have run and are NOT reverted, pre-deploy backup: $backup"
  else
    failure="${NEW:0:8} failed (no new migrations)"
  fi
  log "FAILED, rolling code back to ${CUR:0:8}; $failure"
  git checkout -q --detach "$CUR"
  ( cd "$APP/web" && rails_env && bundle install --quiet && bundle exec rails assets:precompile >/dev/null ) || log "rollback rebuild failed"
  fix_owner
  systemctl restart rupert-web rupert-jobs
  if health; then
    log "rollback healthy"; failure="$failure; rolled back to ${CUR:0:8}"
  else
    log "ROLLBACK ALSO UNHEALTHY, needs a human"; failure="$failure; rollback to ${CUR:0:8} is ALSO UNHEALTHY, needs a human"
  fi
  write_json last-deploy.json failed "$failure"
  write_json status.json failed "$failure"
  exit 1
fi
rm -f "$STATE/failed-sha"
write_json last-deploy.json deployed "deployed ${NEW:0:8}, healthy"
report deployed "deployed ${NEW:0:8}, healthy"
