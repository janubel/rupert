//! Tenant registry: one SQLite file per tenant, opened lazily and capped by an
//! idle-evicting cache so memory is bounded no matter how many tenants exist.
use crate::migrate;
use moka::sync::Cache;
use parking_lot::Mutex;
use rusqlite::Connection;
use std::{path::PathBuf, sync::{Arc, OnceLock, atomic::{AtomicBool, Ordering}}, time::Duration};
use tokio::sync::oneshot;
use crate::{Adjust, Item};

/// Tunables, read once from the environment so one binary can be A/B tested.
pub struct Cfg { pub cache_kb: i64, pub mmap_mb: i64, pub readers: usize, pub group_commit: bool }
pub fn cfg() -> &'static Cfg {
    static C: OnceLock<Cfg> = OnceLock::new();
    C.get_or_init(|| {
        let e = |k: &str, d: i64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
        Cfg { cache_kb: e("RUPERT_CACHE_KB", 512), mmap_mb: e("RUPERT_MMAP_MB", 0), readers: e("RUPERT_READERS", 8) as usize, group_commit: e("RUPERT_GROUP_COMMIT", 1) == 1 }
    })
}

pub struct Pending { a: Adjust, tx: oneshot::Sender<Result<Item, u16>> }

pub struct TenantDb {
    pub writer: Mutex<Connection>,
    readers: Mutex<Vec<Connection>>,
    path: PathBuf,
    queue: Mutex<Vec<Pending>>,
    flushing: AtomicBool,
}

fn tune(c: &Connection) -> rusqlite::Result<()> {
    let g = cfg();
    c.execute_batch(&format!(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;
         PRAGMA temp_store=MEMORY; PRAGMA cache_size=-{}; PRAGMA mmap_size={};
         PRAGMA foreign_keys=ON;", g.cache_kb, g.mmap_mb * 1048576))
}

impl TenantDb {
    fn open(path: PathBuf) -> rusqlite::Result<Self> {
        let w = Connection::open(&path)?;
        tune(&w)?;
        migrate::apply(&w, migrate::TENANT)?;
        Ok(Self { writer: Mutex::new(w), readers: Mutex::new(Vec::new()), path, queue: Mutex::new(Vec::new()), flushing: AtomicBool::new(false) })
    }
    /// Borrow a read connection (WAL allows readers concurrent with the writer).
    pub fn with_reader<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> rusqlite::Result<T> {
        let c = match self.readers.lock().pop() {
            Some(c) => c,
            None => {
                let c = Connection::open_with_flags(&self.path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
                let g = cfg();
                c.execute_batch(&format!("PRAGMA busy_timeout=5000; PRAGMA cache_size=-{}; PRAGMA mmap_size={};", g.cache_kb / 2, g.mmap_mb * 1048576))?;
                c
            }
        };
        let r = f(&c);
        let mut pool = self.readers.lock();
        if pool.len() < cfg().readers { pool.push(c); }
        r
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
                if self.queue.lock().is_empty() || self.flushing.swap(true, Ordering::AcqRel) { return; }
                continue;
            }
            let results = {
                let mut c = self.writer.lock();
                (|| -> rusqlite::Result<Vec<Result<Item, u16>>> {
                    let tx = c.transaction()?;
                    let mut out = Vec::with_capacity(batch.len());
                    for p in batch.iter() {
                        let now = crate::now();
                        let n = tx.prepare_cached("UPDATE inventory_items SET qty=qty+?2, updated_at=?3 WHERE sku=?1")?
                            .execute((&p.a.sku, p.a.delta, now))?;
                        if n == 0 { out.push(Err(404)); continue; }
                        tx.prepare_cached("INSERT INTO movements(sku,delta,reason,at) VALUES (?1,?2,?3,?4)")?
                            .execute((&p.a.sku, p.a.delta, &p.a.reason, now))?;
                        let item = tx.prepare_cached("SELECT sku,name,qty FROM inventory_items WHERE sku=?1")?
                            .query_row([&p.a.sku], |r| Ok(Item { sku: r.get(0)?, name: r.get(1)?, qty: r.get(2)? }))?;
                        out.push(Ok(item));
                    }
                    tx.commit()?;
                    Ok(out)
                })()
            };
            match results {
                Ok(rs) => for (p, r) in batch.into_iter().zip(rs) { let _ = p.tx.send(r); },
                Err(_) => for p in batch { let _ = p.tx.send(Err(500)); },
            }
        }
    }
}

pub struct Registry {
    dir: PathBuf,
    open: Cache<String, Arc<TenantDb>>,
    pub hosts: Cache<String, Option<String>>, // host -> tenant id (negative results cached too)
    pub central: Mutex<Connection>,
}

impl Registry {
    pub fn new(dir: PathBuf, max_open: u64) -> rusqlite::Result<Self> {
        std::fs::create_dir_all(dir.join("tenants")).ok();
        let central = Connection::open(dir.join("central.db"))?;
        tune(&central)?;
        migrate::apply(&central, migrate::CENTRAL)?;
        Ok(Self {
            dir,
            open: Cache::builder().max_capacity(max_open).time_to_idle(Duration::from_secs(300)).build(),
            hosts: Cache::builder().max_capacity(100_000).time_to_live(Duration::from_secs(60)).build(),
            central: Mutex::new(central),
        })
    }
    pub fn tenant_for_host(&self, host: &str) -> Option<String> {
        let host = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
        self.hosts.get_with(host.clone(), || {
            self.central.lock().query_row("SELECT tenant_id FROM domains WHERE host=?1", [&host], |r| r.get(0)).ok()
        })
    }
    pub fn db(&self, tenant: &str) -> rusqlite::Result<Arc<TenantDb>> {
        if let Some(d) = self.open.get(tenant) { return Ok(d); }
        let d = Arc::new(TenantDb::open(self.dir.join("tenants").join(format!("{tenant}.db")))?);
        self.open.insert(tenant.to_string(), d.clone());
        Ok(d)
    }
    pub fn create_tenant(&self, id: &str, name: &str, host: &str) -> rusqlite::Result<()> {
        let now = crate::now();
        let c = self.central.lock();
        c.execute("INSERT OR IGNORE INTO tenants VALUES (?1,?2,?3)", (id, name, now))?;
        c.execute("INSERT OR REPLACE INTO domains VALUES (?1,?2)", (host, id))?;
        drop(c);
        self.db(id).map(|_| ())
    }
}
