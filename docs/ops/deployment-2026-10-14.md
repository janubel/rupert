# SER8 Rupert deployment — October 14, 2026

Verified on the live `rupert` Incus instance on SER8, approximately 8:01–8:05 PM America/New_York (October 15, 00:01–00:05 UTC).

## Release

- Previous code: `d93eb5f1012aa1e04de23691c88a5f445514aa1e`.
- Deployed application release: `11af6b8d74accc012ef3d0cdeab13a8d38c31301` (PR #18).
- Production checkout was clean and advanced by fast-forward. No database schema or dependency-version changes were required.
- Bundler dependency checks, Rails eager-load checks, Tailwind build and asset compilation passed on the host.
- Web and job services use a root-owned `50-rupert-frozen-bundle.conf` drop-in setting `BUNDLE_FROZEN=true`. The app user cannot rewrite the root-owned release lockfile. Encryption keys and commerce credentials were preserved.
- Activated with a host-side `incus restart rupert`, following the existing AppArmor restart guidance.

## Recovery points

A fresh consistent SQLite snapshot and private configuration backup are retained in `/var/backups/rupert/pre-roadmap-11af6b8-K7uoffQY`. The compressed database was restored into a separate file, compared byte-for-byte, and passed integrity and foreign-key checks. A table inventory, per-table row counts, database digest, prior release SHA and service definitions are retained with it. The backup directory is private and includes credentials; its contents are not published.

Incus snapshot: `pre-roadmap-11af6b8-20261014`. This complements the consistent database backup. Existing snapshots and backups were preserved.

## Observed after restart

| Check | Result |
| --- | --- |
| Public `/up` | HTTP 200 |
| Public `/roadmap` while signed out | HTTP 302 to `/login`, normal sign-in page rendered |
| Web / jobs / local backup timer | Active |
| Web / job restart counters | 0 |
| Loaded SQLite | 3.53.2 |
| Journal / configured lock wait | WAL / 5,000 ms |
| Job threads | 1 (new SQLite default) |
| Live job processes | One supervisor, dispatcher, worker and scheduler |
| Ready jobs | 0 |
| Failed jobs | 1, already present before deployment; no increase |
| Worker heartbeat | Fresh; observed at 8:04:28 PM EDT |
| Latest successful sync | 8:00 PM EDT, before the restart |
| Feature catalog / route | 49 entries readable; `/roadmap` resolves to the new controller |
| Planner maintenance | `ops:sqlite:optimize` completed |
| Database integrity / foreign keys | `ok` / no violations |

The original application release passed 369 tests on each database adapter and GitHub CI before deployment. The signed-in catalog and diagnostics were browser-tested locally; production browser checks exercised the normal signed-out access path. This record does not claim every listed business workflow was retested against live commerce accounts.

## Remaining verification

Production latency/load benchmarking and an off-host restore drill were not performed. The app's Google Drive backup history contained no recorded successful attempt during this check; that alone does not establish whether other off-host copies exist. Keep these separate from the verified local backup/restore and deployment results. Broader planned features in the roadmap remain unimplemented.
