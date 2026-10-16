//! Embedded, ordered migrations tracked with SQLite `PRAGMA user_version`.
//! Every tenant file runs the same list; central uses its own list.
use rusqlite::Connection;

pub const TENANT: &[&str] = &[
    "CREATE TABLE inventory_items (
        sku TEXT PRIMARY KEY, name TEXT NOT NULL, qty INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE movements (
        id INTEGER PRIMARY KEY, sku TEXT NOT NULL, delta INTEGER NOT NULL,
        reason TEXT NOT NULL, at INTEGER NOT NULL);
     CREATE INDEX movements_sku ON movements(sku, id);",
];

pub const CENTRAL: &[&str] = &[
    "CREATE TABLE tenants (id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE domains (host TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id)) WITHOUT ROWID;
     CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, pw_hash TEXT NOT NULL);
     CREATE TABLE memberships (user_id INTEGER NOT NULL, tenant_id TEXT NOT NULL, role TEXT NOT NULL,
        PRIMARY KEY (user_id, tenant_id)) WITHOUT ROWID;
     CREATE TABLE invites (token TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, role TEXT NOT NULL,
        expires_at INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE shares (from_tenant TEXT NOT NULL, to_tenant TEXT NOT NULL, scope TEXT NOT NULL,
        PRIMARY KEY (from_tenant, to_tenant, scope)) WITHOUT ROWID;",
];

pub fn central() -> Vec<&'static str> {
    let mut v = CENTRAL.to_vec();
    v.push(CENTRAL_AUTH);
    v
}

pub fn apply(conn: &Connection, list: &[&str]) -> rusqlite::Result<()> {
    let have = conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))? as usize;
    for (i, sql) in list.iter().enumerate().skip(have) {
        conn.execute_batch(&format!("BEGIN; {sql}; PRAGMA user_version = {}; COMMIT;", i + 1))?;
    }
    Ok(())
}

/// Central migration 2: auth. Appended to CENTRAL by `central_auth()` below so the
/// original list stays append-only and `user_version` stays meaningful.
pub const CENTRAL_AUTH: &str = "
    ALTER TABLE users ADD COLUMN name TEXT NOT NULL DEFAULT '';
    ALTER TABLE users ADD COLUMN active INTEGER NOT NULL DEFAULT 1;
    ALTER TABLE users ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE tenants ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
    CREATE TABLE sessions (digest TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, revoked_at INTEGER) WITHOUT ROWID;
    CREATE TABLE api_tokens (id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, user_id INTEGER NOT NULL,
        name TEXT NOT NULL, digest TEXT NOT NULL UNIQUE, hint TEXT NOT NULL, scopes TEXT NOT NULL,
        expires_at INTEGER, revoked_at INTEGER, created_at INTEGER NOT NULL) WITHOUT ROWID;
    DROP TABLE invites;
    CREATE TABLE invites (digest TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, email TEXT NOT NULL,
        role TEXT NOT NULL, invited_by INTEGER NOT NULL, expires_at INTEGER NOT NULL,
        accepted_at INTEGER) WITHOUT ROWID;
    CREATE TABLE audit (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, tenant_id TEXT, user_id INTEGER,
        action TEXT NOT NULL, detail TEXT);
    CREATE INDEX audit_tenant ON audit(tenant_id, id);
";
