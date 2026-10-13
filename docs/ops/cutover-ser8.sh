#!/usr/bin/env bash
# Deploy this branch to the live Rupert container on SER8 and switch it from PostgreSQL to SQLite, with automatic
# rollback. Run INSIDE the `rupert` Incus container as root:
#
#   ssh sdolbec@10.20.0.117 'incus exec rupert -- bash -s' < docs/ops/cutover-ser8.sh
#   REF=main ... (default REF=ui-ux-and-organize; use main once PR #12 is merged)
#
# Phases (each is checked; any failure restores the previous code and database setting and restarts the app):
#   1 code     git checkout REF, bundle install, assets, db:migrate on PostgreSQL, restart, health check
#   2 cutover  stop app, ./bin/migrate-to-sqlite (verified copy), set RUPERT_DB_ADAPTER=sqlite3, start, health check
# PostgreSQL (on rupert-db) is never modified except by normal Rails migrations in phase 1.
# Safety nets that already exist: Incus snapshot `rupert@pre-sqlite-cutover`, and /var/backups/rupert/pre-sqlite-*.dump.
set -Eeuo pipefail   # -E so the ERR trap also fires inside functions

REF="${REF:-ui-ux-and-organize}"
APP=/opt/rupert
ENVF=/etc/rupert.env
export PATH=/opt/rbenv/versions/4.0.6/bin:$PATH
PREV="$(git -C "$APP" rev-parse HEAD)"
ENV_BACKUP="/var/backups/rupert/rupert.env.before-cutover-$(date +%Y%m%d-%H%M)"
phase=start

as_app() { runuser -m -u rupert -- env HOME=/tmp/rupert-home RAILS_ENV=production "$@"; }
healthy() {
  for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' http://127.0.0.1:3000/up)" = 200 ] && return 0
    sleep 2
  done
  return 1
}

# systemd cannot kill the cgroup inside this container ("Permission denied"), so a stopped unit can leave Puma
# running and holding port 3000. Stop it, then make sure no Puma is left.
stop_app() {
  systemctl stop rupert-web || true
  pkill -TERM -u rupert -f '[p]uma' || true
  for _ in $(seq 1 30); do pgrep -u rupert -f '[p]uma' >/dev/null || return 0; sleep 1; done
  pkill -KILL -u rupert -f '[p]uma' || true
  sleep 1
}
start_app() { systemctl reset-failed rupert-web 2>/dev/null || true; systemctl start rupert-web; }

rollback() {
  echo "!! FAILED in phase '$phase' - rolling back" >&2
  stop_app
  [ -f "$ENV_BACKUP" ] && install -m 600 "$ENV_BACKUP" "$ENVF"
  git -C "$APP" checkout -q "$PREV" || true
  (cd "$APP/web" && bundle install --quiet) || true
  start_app || true
  healthy && echo "rolled back to $PREV; app is up on PostgreSQL" >&2 || echo "ROLLBACK DID NOT RECOVER THE APP: restore with: incus snapshot restore rupert pre-sqlite-cutover" >&2
  exit 1
}
trap rollback ERR

install -d -m 700 /var/backups/rupert /tmp/rupert-home
chown rupert:rupert /tmp/rupert-home
install -m 600 "$ENVF" "$ENV_BACKUP"
set -a; . "$ENVF"; set +a

phase=prereqs
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
healthy || { echo "app is not healthy before we start; refusing to continue" >&2; trap - ERR; exit 1; }

phase="code ($REF)"
git -C "$APP" fetch -q origin "$REF:refs/remotes/origin/$REF"
git -C "$APP" checkout -q -B "$REF" "origin/$REF"
cd "$APP/web"
BUNDLE_SILENCE_ROOT_WARNING=1 bundle install --quiet
chown -R rupert:rupert tmp log storage public app/assets/builds
chgrp rupert Gemfile.lock && chmod g+rw Gemfile.lock
as_app bundle exec bin/rails tailwindcss:build >/dev/null
as_app bundle exec bin/rails assets:precompile >/dev/null
as_app bundle exec bin/rails db:migrate
stop_app
start_app
healthy
echo "phase 1 ok: new code running on PostgreSQL"

phase=cutover
stop_app
rm -f storage/production.sqlite3 storage/production.sqlite3-wal storage/production.sqlite3-shm
ENV_FILE="" BACKUP_DIR=/var/backups/rupert runuser -m -u rupert -- env HOME=/tmp/rupert-home "$APP/bin/migrate-to-sqlite"
grep -q '^RUPERT_DB_ADAPTER=' "$ENVF" && sed -i '/^RUPERT_DB_ADAPTER=/d' "$ENVF"
echo 'RUPERT_DB_ADAPTER=sqlite3' >> "$ENVF"
start_app
healthy
count=$(RUPERT_DB_ADAPTER=sqlite3 as_app bundle exec bin/rails runner 'puts Core::Customer.count rescue puts ActiveRecord::Base.connection.tables.size')
echo "app answers on SQLite (sample count: $count)"

trap - ERR
echo
echo "DONE. Rupert now runs on SQLite ($(du -h storage/production.sqlite3 | cut -f1))."
echo "Roll back any time: sed -i '/^RUPERT_DB_ADAPTER=/d' $ENVF && systemctl restart rupert-web  (PostgreSQL on rupert-db is untouched)."
