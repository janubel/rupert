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
export RAILS_ENV=production PATH=${RUPERT_AUTODEPLOY_PATH:-/opt/rbenv/versions/4.0.6/bin:/usr/local/bin:/usr/bin:/bin}
log() { echo "autodeploy: $*"; }

exec 9>"$LOCK"
flock -n 9 || { log "another deploy is running"; exit 0; }

cd "$APP" || exit 1
if [ -n "$(git status --porcelain)" ]; then log "checkout is dirty, skipping"; exit 0; fi
git fetch -q origin main || { log "fetch failed"; exit 0; }
CUR=$(git rev-parse HEAD); NEW=$(git rev-parse origin/main)
[ "$CUR" = "$NEW" ] && { log "up to date at ${CUR:0:8}"; exit 0; }
git merge-base --is-ancestor "$CUR" "$NEW" || { log "origin/main is not a fast-forward of $CUR, skipping"; exit 0; }
if [ "$(cat "$STATE/failed-sha" 2>/dev/null)" = "$NEW" ]; then
  log "${NEW:0:8} already failed to deploy, waiting for a newer commit (rm $STATE/failed-sha to retry)"; exit 0
fi

# Both CI matrix jobs must be green. Re-runs leave the earlier check runs in the
# list, so only the most recent run of each job counts.
ci=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/commits/$NEW/check-runs?per_page=100" | python3 -c '
import json, re, sys
latest = {}
for r in json.load(sys.stdin)["check_runs"]:
    if re.fullmatch(r"CI \((sqlite3|postgresql)\)", r["name"]) and r["id"] > latest.get(r["name"], {"id": -1})["id"]:
        latest[r["name"]] = r
done = [r["conclusion"] for r in latest.values()]
if any(c in ("failure", "cancelled", "timed_out") for c in done): print("red")
elif len(latest) == 2 and all(c == "success" for c in done): print("green")
else: print("pending")') || ci=unknown
if [ "$ci" != green ]; then log "CI for ${NEW:0:8} is $ci, not deploying yet"; exit 0; fi

migrations=$(git diff --name-only --diff-filter=A "$CUR" "$NEW" -- web/db/migrate | wc -l)
log "deploying ${CUR:0:8} -> ${NEW:0:8} ($migrations new migration(s))"
[ "${DRY_RUN:-0}" = 1 ] && { log "dry run, stopping"; exit 0; }

mkdir -p "$BACKUPS" "$STATE"; chmod 700 "$BACKUPS" "$STATE"
backup="$BACKUPS/production-$(date +%Y%m%d-%H%M%S)-${CUR:0:8}.sqlite3"
( umask 077; sqlite3 web/storage/production.sqlite3 ".backup $backup" ) || { log "backup failed, aborting"; exit 1; }
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
    log "FAILED, rolling code back to ${CUR:0:8}; $migrations migration(s) may have run and are NOT reverted, pre-deploy backup: $backup"
  else
    log "FAILED, rolling code back to ${CUR:0:8} (no new migrations)"
  fi
  git checkout -q --detach "$CUR"
  ( cd "$APP/web" && rails_env && bundle install --quiet && bundle exec rails assets:precompile >/dev/null ) || log "rollback rebuild failed"
  fix_owner
  systemctl restart rupert-web rupert-jobs
  health && log "rollback healthy" || log "ROLLBACK ALSO UNHEALTHY, needs a human"
  exit 1
fi
rm -f "$STATE/failed-sha"
log "deployed ${NEW:0:8}, healthy"
