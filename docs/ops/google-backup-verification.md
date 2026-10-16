# Google Drive backup verification

Backups use platform-owned encrypted Drive credentials and the registered `/auth/google/callback` redirect. Google sign-in and backup consent have separate random state, with the backup purpose prefix, a ten-minute expiry, and an active platform administrator plus matching actor and workspace required before exchange. Backup consent never signs in or provisions an account. Register the same exact HTTPS callback for the Drive client; do not rotate payment credentials.

Connect from Settings as the platform administrator and approve Google’s `drive.file` consent. The server stores the returned refresh token in encrypted platform settings. A browser login alone is not unattended backup authorization.

A successful backup means a consistent database snapshot was uploaded privately, its size and Drive MD5 matched, and a fresh downloaded copy matched the local SHA-256 and size. Verification happens before retention pruning or the success log. Failed verification retains previous successful backups and reports failure. Temporary snapshots and verification downloads are removed. Production schedules `BackupJob` every six hours; manual backup uses the same verification.

A database snapshot still needs the original Rails encryption keys to decrypt protected records after disaster recovery. Keep those keys in a private secret manager or protected deployment backup, never public Git. Validate recovery against an isolated copy; never restore over the live database as a test.

## Deferred Google account access

On October 15, 2026 the registered callback was deployed and accepted by Google. Backup consent then returned `403 access_denied`: the configured OAuth app is in Testing and the requested Drive account is not a developer-approved tester. No refresh token or successful cloud backup has been established. The owner deferred the Google Cloud sign-in; do not label backups connected or verified until consent and an actual upload/download succeed.

Resume with the account that owns the configured OAuth client. Review its audience/test-user configuration, the exact registered callback and Drive API enablement, then let the platform owner grant `drive.file` consent from Rupert Settings. Adding a tester can enable a trial, but external apps in Testing receive refresh tokens that expire after seven days for Drive scopes; review production readiness for durable unattended backups. See [Google refresh-token expiration](https://developers.google.com/identity/protocols/oauth2#expiration). Do not change the unrelated payment credentials.

After consent, run **Back up now**, check the private Drive file and successful verified log, and validate a downloaded SQLite backup with `PRAGMA integrity_check` / `foreign_key_check` against an isolated copy. The six-hour recurring job and seven-backup retention are already configured. A deployment backup on SER8 is local recovery protection, not proof of a Google upload.
