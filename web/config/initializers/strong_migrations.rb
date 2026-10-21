# frozen_string_literal: true

# Catch risky migrations when they are written. Auto-deploy runs db:migrate
# unattended and does not roll migrations back, so a migration that drops or
# renames a column in use, rewrites a table or holds a long lock must be
# rewritten safely (or wrapped in `safety_assured` after review) first.
#
# Production (SER8) uses SQLite: strong_migrations warns "Unsupported adapter"
# there but still runs its adapter-independent checks (remove/rename column,
# change column type, raw SQL, ...). PostgreSQL also gets lock and index checks.

# Migrations up to this one were written before the gem was added.
StrongMigrations.start_after = 20261020150000

# Oldest PostgreSQL in use (CI runs postgres:16).
StrongMigrations.target_version = 16
