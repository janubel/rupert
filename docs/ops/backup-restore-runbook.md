# Backup and restore runbook

This page is retained as a compatibility link for older bookmarks. The current
source of truth for backup layers, freshness, key handling and recovery is
[Rupert backups](backups.md). Follow that runbook for an actual restore.

The manual stop, replace and restart sequence previously printed here is
retired. It predates the current SER8 backup and deployment procedures and is
not evidence that a restore has been rehearsed. Do not use this page to restore
production data. A restore test belongs in a new isolated destination; a live
recovery requires the current operator procedure, a verified backup and its
matching encryption keys.

## Recovery acceptance checklist

Before relying on recovery, record all of the following for a recent encrypted
backup from outside SER8:

- The ciphertext digest verifies, and decryption succeeds with the separately
  escrowed key.
- The restored SQLite file passes `PRAGMA integrity_check` and
  `PRAGMA foreign_key_check`; expected table counts and retained files match
  the selected recovery point.
- The matching environment copy contains the original Rails encryption keys,
  and a designated nonproduction restore can read encrypted settings.
- The measured restore time and backup age meet the owner's recovery targets.
- The installed host and mirror scripts match the reviewed repository versions;
  the latest backup and restore-drill status is fresh and successful.
- A code rollback is rehearsed independently from a database rollback. Keep
  newer SQLite business writes and additive tables; the frozen PostgreSQL
  cutover copy is not a current recovery database.

The live SER8 release gate remains tracked in
[issue #202](https://github.com/techmore/rupert/issues/202). A passing local
fixture or CI run does not establish a current off-host restore, production
health or operator acceptance.

## Encryption key rotation

`RAILS_ENCRYPTION_PRIMARY_KEY`, `RAILS_ENCRYPTION_DETERMINISTIC_KEY` and
`RAILS_ENCRYPTION_KEY_DERIVATION_SALT` must not be replaced directly; encrypted
columns would become unreadable. Rotation requires adding a new primary key
while retaining the old key, re-encrypting records, and verifying recovery
against a protected backup. `SECRET_KEY_BASE` rotation signs users out. See the
[operator runbook](operator-runbook.md) for credential rotation.
