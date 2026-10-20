#!/usr/bin/env bash
# Auto-deploy origin/main to /opt/rupert when app CI is green. Fast-forward only,
# clean checkout only, DB backup first, health check, code rollback on failure.
# DRY_RUN=1 reports what it would do without changing anything.
set -uo pipefail
APP=/opt/rupert
REPO=techmore/rupert
HOST=rupert.stoverparc.org
BACKUPS=/var/backups/rupert-autodeploy
export RAILS_ENV=production PATH=/opt/rbenv/versions/4.0.6/bin:/usr/local/bin:/usr/bin:/bin
log() { echo "autodeploy: $*"; }

exec 9>/run/rupert-autodeploy.lock
flock -n 9 || { log "another deploy is running"; exit 0; }

cd "$APP" || exit 1
if [ -n "$(git status --porcelain)" ]; then log "checkout is dirty, skipping"; exit 0; fi
git fetch -q origin main || { log "fetch failed"; exit 0; }
CUR=$(git rev-parse HEAD); NEW=$(git rev-parse origin/main)
[ "$CUR" = "$NEW" ] && { log "up to date at ${CUR:0:8}"; exit 0; }
git merge-base --is-ancestor "$CUR" "$NEW" || { log "origin/main is not a fast-forward of $CUR, skipping"; exit 0; }

ci=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/commits/$NEW/check-runs?per_page=100" | ruby -rjson -e '
  runs = JSON.parse(STDIN.read)["check_runs"].select { |r| r["name"] =~ /\ACI \((sqlite3|postgresql)\)\z/ }
  names = runs.map { |r| r["name"] }.uniq
  if names.size < 2 then puts "pending"
  elsif runs.all? { |r| r["conclusion"] == "success" } then puts "green"
  elsif runs.any? { |r| %w[failure cancelled timed_out].include?(r["conclusion"]) } then puts "red"
  else puts "pending" end') || ci=unknown
if [ "$ci" != green ]; then log "CI for ${NEW:0:8} is $ci, not deploying yet"; exit 0; fi

log "deploying ${CUR:0:8} -> ${NEW:0:8}"
[ "${DRY_RUN:-0}" = 1 ] && { log "dry run, stopping"; exit 0; }

mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
sqlite3 web/storage/production.sqlite3 ".backup $BACKUPS/production-$(date +%Y%m%d-%H%M%S)-${CUR:0:8}.sqlite3" || { log "backup failed, aborting"; exit 1; }
ls -1t "$BACKUPS"/*.sqlite3 | tail -n +6 | xargs -r rm -f

health() {
  for _ in $(seq 1 15); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H 'X-Forwarded-Proto: https' localhost:3000/up)" = 200 ] \
      && systemctl is-active --quiet rupert-web rupert-jobs && return 0
    sleep 2
  done; return 1
}
build() {
  ( cd "$APP/web" && set -a && . /etc/rupert.env && set +a \
    && bundle install --quiet && bundle exec rails db:migrate && bundle exec rails assets:precompile >/dev/null )
}

git checkout -q --detach "$NEW" && build && { chown -R rupert:rupert web/storage web/public web/tmp web/log 2>/dev/null; systemctl restart rupert-web rupert-jobs; } && health
if [ $? -ne 0 ]; then
  log "FAILED, rolling code back to ${CUR:0:8} (database migrations are NOT reverted; backup in $BACKUPS)"
  git checkout -q --detach "$CUR"
  ( cd "$APP/web" && set -a && . /etc/rupert.env && set +a && bundle install --quiet && bundle exec rails assets:precompile >/dev/null )
  systemctl restart rupert-web rupert-jobs
  health && log "rollback healthy" || log "ROLLBACK ALSO UNHEALTHY, needs a human"
  exit 1
fi
log "deployed ${NEW:0:8}, healthy"
