# Google Drive backup verification

Backups use platform-owned encrypted Drive credentials and the registered `/auth/google/callback` redirect. Google sign-in and backup consent have separate random state, with the backup purpose prefix, a ten-minute expiry, and an active platform administrator plus matching actor and workspace required before exchange. Backup consent never signs in or provisions an account. Register the same exact HTTPS callback for the Drive client; do not rotate payment credentials.

Connect from Settings as the platform administrator and approve Google’s `drive.file` consent. The server stores the returned refresh token in encrypted platform settings. A browser login alone is not unattended backup authorization.

A successful backup means a consistent database snapshot was uploaded privately, its size and Drive MD5 matched, and a fresh downloaded copy matched the local SHA-256 and size. Verification happens before retention pruning or the success log. Failed verification retains previous successful backups and reports failure. Temporary snapshots and verification downloads are removed. Production schedules `BackupJob` every six hours; manual backup uses the same verification.

A database snapshot still needs the original Rails encryption keys to decrypt protected records after disaster recovery. Keep those keys in a private secret manager or protected deployment backup, never public Git. Validate recovery against an isolated copy; never restore over the live database as a test.
