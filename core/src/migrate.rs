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
    // 2: read-only mirrors of Shopify/Square, sync history, change feed, sealed connections.
    "CREATE TABLE shopify_variants (id TEXT PRIMARY KEY, product_id TEXT NOT NULL, title TEXT NOT NULL, sku TEXT,
        price REAL, inventory_item_id TEXT, qty INTEGER NOT NULL DEFAULT 0, tracked INTEGER NOT NULL DEFAULT 0,
        synced_run INTEGER NOT NULL) WITHOUT ROWID;
     CREATE INDEX shopify_variants_sku ON shopify_variants(sku);
     CREATE TABLE square_variations (id TEXT PRIMARY KEY, item_id TEXT NOT NULL, name TEXT NOT NULL, sku TEXT,
        qty INTEGER NOT NULL DEFAULT 0, synced_run INTEGER NOT NULL) WITHOUT ROWID;
     CREATE INDEX square_variations_sku ON square_variations(sku);
     CREATE TABLE square_counts (variation_id TEXT NOT NULL, location_id TEXT NOT NULL, qty INTEGER NOT NULL,
        synced_run INTEGER NOT NULL, PRIMARY KEY (variation_id, location_id)) WITHOUT ROWID;
     CREATE TABLE sync_runs (id INTEGER PRIMARY KEY, source TEXT NOT NULL, status TEXT NOT NULL,
        started_at INTEGER NOT NULL, finished_at INTEGER, details TEXT, error TEXT);
     CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, kind TEXT NOT NULL,
        key TEXT, data TEXT NOT NULL);
     CREATE TABLE connections (provider TEXT PRIMARY KEY, sealed BLOB NOT NULL, updated_at INTEGER NOT NULL) WITHOUT ROWID;",
    // 3: the outbox does not need AUTOINCREMENT (pruning always keeps the newest rows, so ids
    // never repeat); dropping it removes a sqlite_sequence write from every event insert.
    "CREATE TABLE events_new (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT, data TEXT NOT NULL);
     INSERT INTO events_new SELECT id,at,kind,key,data FROM events;
     DROP TABLE events;
     ALTER TABLE events_new RENAME TO events;",
    // 4: per-tenant settings (realtime outbox on/off).
    "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;",
    // 5: Shopify product status (ACTIVE/DRAFT/ARCHIVED); production Rupert mirrors all of them.
    "ALTER TABLE shopify_variants ADD COLUMN product_status TEXT NOT NULL DEFAULT 'ACTIVE';",
    // 6: per-location stock. Shopify locations + per-(variant, location) available (clamped like Rails),
    // Square location names. Square per-location counts already live in square_counts.
    "CREATE TABLE shopify_locations (id TEXT PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL,
        is_primary INTEGER NOT NULL DEFAULT 0, synced_run INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE shopify_levels (variant_id TEXT NOT NULL, location_id TEXT NOT NULL, qty INTEGER NOT NULL,
        raw_qty INTEGER NOT NULL, synced_run INTEGER NOT NULL, PRIMARY KEY (variant_id, location_id)) WITHOUT ROWID;
     CREATE INDEX shopify_levels_loc ON shopify_levels(location_id);
     CREATE TABLE square_locations (id TEXT PRIMARY KEY, name TEXT NOT NULL, synced_run INTEGER NOT NULL) WITHOUT ROWID;",
    // 7: how hard we lean on each provider's API. 10-minute buckets, per provider and operation.
    "CREATE TABLE api_usage (bucket INTEGER NOT NULL, provider TEXT NOT NULL, op TEXT NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0, throttled INTEGER NOT NULL DEFAULT 0, retries INTEGER NOT NULL DEFAULT 0,
        errors INTEGER NOT NULL DEFAULT 0, wait_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (bucket, provider, op)) WITHOUT ROWID;",
    // 8: read-only order mirror. Deliberately no customer name/email/phone/address: sales data only.
    "CREATE TABLE orders (id TEXT PRIMARY KEY, source TEXT NOT NULL, name TEXT, created_at TEXT NOT NULL, updated_at TEXT,
        cancelled_at TEXT, status TEXT, total REAL, currency TEXT, line_count INTEGER NOT NULL DEFAULT 0, synced_run INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
     CREATE INDEX orders_source_created ON orders(source, created_at);
     CREATE TABLE order_lines (order_id TEXT NOT NULL, line_id TEXT NOT NULL, sku TEXT, variant_id TEXT, title TEXT, qty INTEGER NOT NULL, price REAL,
        PRIMARY KEY (order_id, line_id)) WITHOUT ROWID;
     CREATE INDEX order_lines_sku ON order_lines(sku);
     CREATE TABLE webhook_events (id TEXT PRIMARY KEY, provider TEXT NOT NULL, topic TEXT NOT NULL, received_at INTEGER NOT NULL, outcome TEXT) WITHOUT ROWID;
     CREATE INDEX webhook_events_received ON webhook_events(received_at);",
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

/// Central migration 3: sync schedules (scanned by the scheduler, so they live in the central DB).
pub const CENTRAL_SCHEDULES: &str = "
    CREATE TABLE schedules (tenant_id TEXT NOT NULL, source TEXT NOT NULL, every_secs INTEGER NOT NULL,
        next_due INTEGER NOT NULL, fails INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tenant_id, source)) WITHOUT ROWID;
    CREATE INDEX schedules_due ON schedules(next_due);
";

/// Central migration 4: webhook URL tokens (digest only, like API tokens).
pub const CENTRAL_HOOKS: &str = "
    CREATE TABLE webhook_tokens (digest TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, created_at INTEGER NOT NULL) WITHOUT ROWID;
    CREATE INDEX webhook_tokens_tenant ON webhook_tokens(tenant_id);
";

pub fn central() -> Vec<&'static str> {
    let mut v = CENTRAL.to_vec();
    v.push(CENTRAL_AUTH);
    v.push(CENTRAL_SCHEDULES);
    v.push(CENTRAL_HOOKS);
    v
}

pub fn apply(conn: &Connection, list: &[&str]) -> rusqlite::Result<()> {
    let have = conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))? as usize;
    for (i, sql) in list.iter().enumerate().skip(have) {
        conn.execute_batch(&format!(
            "BEGIN; {sql}; PRAGMA user_version = {}; COMMIT;",
            i + 1
        ))?;
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
