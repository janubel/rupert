#!/bin/sh
set -e

# Remove a potentially pre-existing server.pid for Rails.
# Schema migrations run in the dedicated one-shot `migrate` compose service
# (bin/rails db:prepare) BEFORE web/jobs start — see docker-compose.yml.
if [ -f /app/tmp/pids/server.pid ]; then
  rm -f /app/tmp/pids/server.pid
fi

exec "$@"
