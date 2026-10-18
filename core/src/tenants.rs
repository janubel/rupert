//! Tenant registry: one SQLite file per tenant, opened lazily and capped by an
//! idle-evicting cache so memory is bounded no matter how many tenants exist.
use crate::migrate;
use crate::{Adjust, Item};
use moka::sync::Cache;
use parking_lot::Mutex;
use rusqlite::Connection;
use std::{
    collections::HashSet,
    sync::atomic::{AtomicI64, AtomicUsize},
};
use std::{
    path::PathBuf,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Semaphore, broadcast, oneshot};

/// Tunables, read once from the environment so one binary can be A/B tested.
pub struct Cfg {
    pub cache_kb: i64,
    pub mmap_mb: i64,
    pub readers: usize,
    pub realtime_default: bool,
}
pub fn cfg() -> &'static Cfg {
    static C: OnceLock<Cfg> = OnceLock::new();
    C.get_or_init(|| {
        let e = |k: &str, d: i64| {
            std::env::var(k)
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(d)
        };
        Cfg {
            cache_kb: e("RUPERT_CACHE_KB", 512),
            mmap_mb: e("RUPERT_MMAP_MB", 0),
            readers: e("RUPERT_READERS", 8) as usize,
            realtime_default: e("RUPERT_REALTIME_DEFAULT", 1) == 1,
        }
    })
}

pub struct Pending {
    a: Adjust,
    tx: oneshot::Sender<Result<Item, u16>>,
}

pub struct TenantDb {
    pub writer: Mutex<Connection>,
    readers: Mutex<Vec<Connection>>,
    path: PathBuf,
    queue: Mutex<Vec<Pending>>,
    flushing: AtomicBool,
    pub bus: broadcast::Sender<Arc<crate::feed::Ev>>,
    pub sse_clients: AtomicUsize,
    /// Highest event id published on this tenant; lets a new stream start "now" without a DB read.
    pub last_event: AtomicI64,
    /// Per-tenant realtime outbox switch. Off: no `events` rows, no broadcasts, SSE refuses.
    realtime: AtomicBool,
}

fn tune(c: &Connection) -> rusqlite::Result<()> {
    let g = cfg();
    c.execute_batch(&format!(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;
         PRAGMA temp_store=MEMORY; PRAGMA cache_size=-{}; PRAGMA mmap_size={};
         PRAGMA foreign_keys=ON;",
        g.cache_kb,
        g.mmap_mb * 1048576
    ))
}

impl TenantDb {
    fn open(path: PathBuf, bus: broadcast::Sender<Arc<crate::feed::Ev>>) -> rusqlite::Result<Self> {
        let w = Connection::open(&path)?;
        tune(&w)?;
        migrate::apply(&w, migrate::TENANT)?;
        let last = w.query_row("SELECT coalesce(max(id),0) FROM events", [], |r| {
            r.get::<_, i64>(0)
        })?;
        let rt = w
            .query_row("SELECT value FROM settings WHERE key='realtime'", [], |r| {
                r.get::<_, String>(0)
            })
            .map(|v| v == "1")
            .unwrap_or(cfg().realtime_default);
        Ok(Self {
            writer: Mutex::new(w),
            readers: Mutex::new(Vec::new()),
            path,
            queue: Mutex::new(Vec::new()),
            flushing: AtomicBool::new(false),
            bus,
            sse_clients: AtomicUsize::new(0),
            last_event: AtomicI64::new(last),
            realtime: AtomicBool::new(rt),
        })
    }
    /// Borrow a read connection (WAL allows readers concurrent with the writer).
    pub fn with_reader<T>(
        &self,
        f: impl FnOnce(&Connection) -> rusqlite::Result<T>,
    ) -> rusqlite::Result<T> {
        let c = match self.readers.lock().pop() {
            Some(c) => c,
            None => {
                let c = Connection::open_with_flags(
                    &self.path,
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )?;
                let g = cfg();
                c.execute_batch(&format!(
                    "PRAGMA busy_timeout=5000; PRAGMA cache_size=-{}; PRAGMA mmap_size={};",
                    g.cache_kb / 2,
                    g.mmap_mb * 1048576
                ))?;
                c
            }
        };
        let r = f(&c);
        let mut pool = self.readers.lock();
        if pool.len() < cfg().readers {
            pool.push(c);
        }
        r
    }

    pub fn realtime(&self) -> bool {
        self.realtime.load(Ordering::Relaxed)
    }

    /// Persist and apply the realtime switch. Turning it on writes one `realtime.enabled`
    /// marker so reconnecting clients know events may be missing from the gap and should resync.
    pub fn set_realtime(&self, on: bool) -> rusqlite::Result<()> {
        let mut evs = Vec::new();
        {
            let mut c = self.writer.lock();
            let tx = c.transaction()?;
            tx.execute("INSERT INTO settings VALUES ('realtime', ?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [if on { "1" } else { "0" }])?;
            if on && !self.realtime() {
                evs.push(crate::feed::emit(
                    &tx,
                    "realtime.enabled",
                    None,
                    &serde_json::json!({}),
                )?);
            }
            tx.commit()?;
        }
        self.realtime.store(on, Ordering::Relaxed);
        self.publish(evs);
        Ok(())
    }

    /// Broadcast committed events and advance the "now" cursor.
    pub fn publish(&self, evs: Vec<crate::feed::Ev>) {
        for e in evs {
            let id = e.id;
            let _ = self.bus.send(Arc::new(e));
            self.last_event.fetch_max(id, Ordering::AcqRel);
        }
    }

    /// Group commit: callers enqueue; one leader drains everything pending into a
    /// single transaction, so N concurrent adjusts cost one commit, not N.
    pub fn submit(self: &Arc<Self>, a: Adjust) -> oneshot::Receiver<Result<Item, u16>> {
        let (tx, rx) = oneshot::channel();
        self.queue.lock().push(Pending { a, tx });
        if !self.flushing.swap(true, Ordering::AcqRel) {
            let me = self.clone();
            tokio::task::spawn_blocking(move || me.flush());
        }
        rx
    }

    fn flush(&self) {
        loop {
            let batch = std::mem::take(&mut *self.queue.lock());
            if batch.is_empty() {
                self.flushing.store(false, Ordering::Release);
                // A submit may have raced between take() and the store above.
                if self.queue.lock().is_empty() || self.flushing.swap(true, Ordering::AcqRel) {
                    return;
                }
                continue;
            }
            let mut evs: Vec<crate::feed::Ev> = Vec::new();
            let results = {
                let mut c = self.writer.lock();
                (|| -> rusqlite::Result<Vec<Result<Item, u16>>> {
                    let tx = c.transaction()?;
                    let mut out = Vec::with_capacity(batch.len());
                    for p in batch.iter() {
                        let now = crate::now();
                        let n = tx
                            .prepare_cached(
                                "UPDATE inventory_items SET qty=qty+?2, updated_at=?3 WHERE sku=?1",
                            )?
                            .execute((&p.a.sku, p.a.delta, now))?;
                        if n == 0 {
                            out.push(Err(404));
                            continue;
                        }
                        tx.prepare_cached(
                            "INSERT INTO movements(sku,delta,reason,at) VALUES (?1,?2,?3,?4)",
                        )?
                        .execute((
                            &p.a.sku,
                            p.a.delta,
                            &p.a.reason,
                            now,
                        ))?;
                        let item = tx
                            .prepare_cached(
                                "SELECT sku,name,qty FROM inventory_items WHERE sku=?1",
                            )?
                            .query_row([&p.a.sku], |r| {
                                Ok(Item {
                                    sku: r.get(0)?,
                                    name: r.get(1)?,
                                    qty: r.get(2)?,
                                })
                            })?;
                        evs.extend(crate::feed::emit_if(self.realtime(), &tx, "inventory.adjusted", Some(&p.a.sku), &serde_json::json!({ "delta": p.a.delta, "qty": item.qty, "reason": p.a.reason }))?);
                        out.push(Ok(item));
                    }
                    tx.commit()?;
                    Ok(out)
                })()
            };
            if results.is_ok() {
                self.publish(evs);
            }
            match results {
                Ok(rs) => {
                    for (p, r) in batch.into_iter().zip(rs) {
                        let _ = p.tx.send(r);
                    }
                }
                Err(_) => {
                    for p in batch {
                        let _ = p.tx.send(Err(500));
                    }
                }
            }
        }
    }
}

pub struct Registry {
    dir: PathBuf,
    open: Cache<String, Arc<TenantDb>>,
    pub central: Mutex<Connection>,
    pub auth: crate::auth::AuthState,
    pub master: Option<[u8; 32]>,
    pub sync_running: Mutex<HashSet<(String, String)>>,
    pub sync_sem: Arc<Semaphore>,
    pub sse_total: AtomicUsize,
    pub hook_sem: Arc<Semaphore>,
    pub shutdown: tokio::sync::watch::Sender<bool>,
    pub hook_debounce: Mutex<std::collections::HashMap<(String, String), i64>>,
    pub sse_max: usize,
    buses: Cache<String, broadcast::Sender<Arc<crate::feed::Ev>>>,
}

impl Registry {
    pub fn new(dir: PathBuf, max_open: u64) -> rusqlite::Result<Self> {
        std::fs::create_dir_all(dir.join("tenants")).ok();
        let central = Connection::open(dir.join("central.db"))?;
        tune(&central)?;
        migrate::apply(&central, &migrate::central())?;
        Ok(Self {
            dir,
            open: Cache::builder()
                .max_capacity(max_open)
                .time_to_idle(Duration::from_secs(300))
                .build(),
            central: Mutex::new(central),
            auth: crate::auth::AuthState::new(),
            master: std::env::var("RUPERT_MASTER_KEY").ok().and_then(|v| {
                use base64::{Engine, engine::general_purpose::STANDARD};
                STANDARD.decode(v.trim()).ok()?.try_into().ok()
            }),
            sync_running: Mutex::new(HashSet::new()),
            sync_sem: Arc::new(Semaphore::new(
                std::env::var("RUPERT_SYNC_CONCURRENCY")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(2),
            )),
            sse_total: AtomicUsize::new(0),
            hook_sem: Arc::new(Semaphore::new(4)),
            shutdown: tokio::sync::watch::channel(false).0,
            hook_debounce: Mutex::new(Default::default()),
            sse_max: std::env::var("RUPERT_SSE_MAX")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(1000),
            buses: Cache::builder()
                .max_capacity(10_000)
                .time_to_idle(Duration::from_secs(3600))
                .build(),
        })
    }
    pub fn db(&self, tenant: &str) -> rusqlite::Result<Arc<TenantDb>> {
        if let Some(d) = self.open.get(tenant) {
            return Ok(d);
        }
        let bus = self
            .buses
            .get_with(tenant.to_string(), || broadcast::channel(256).0);
        let d = Arc::new(TenantDb::open(
            self.dir.join("tenants").join(format!("{tenant}.db")),
            bus,
        )?);
        self.open.insert(tenant.to_string(), d.clone());
        Ok(d)
    }
    pub fn data_dir(&self) -> &std::path::Path {
        &self.dir
    }
    pub fn tenant_path(&self, tenant: &str) -> PathBuf {
        self.dir.join("tenants").join(format!("{tenant}.db"))
    }
    pub fn open_tenants(&self) -> u64 {
        self.open.run_pending_tasks();
        self.open.entry_count()
    }

    /// Folds every open database's WAL back into its main file so a stop leaves nothing in `-wal` files.
    pub fn checkpoint_all(&self) -> usize {
        let mut n = 0;
        for (_, db) in self.open.iter() {
            if db
                .writer
                .lock()
                .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
                .is_ok()
            {
                n += 1;
            }
        }
        let _ = self
            .central
            .lock()
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)");
        n
    }

    pub fn create_tenant(&self, id: &str, name: &str, host: &str) -> rusqlite::Result<()> {
        let now = crate::now();
        let c = self.central.lock();
        c.execute(
            "INSERT OR IGNORE INTO tenants(id,name,created_at) VALUES (?1,?2,?3)",
            (id, name, now),
        )?;
        c.execute("INSERT OR REPLACE INTO domains VALUES (?1,?2)", (host, id))?;
        drop(c);
        self.db(id).map(|_| ())
    }
}
