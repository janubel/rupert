//! Read-only mirror sync (Shopify, Square), sealed provider connections, and the
//! mirror read endpoints. Nothing here writes to Shopify or Square: the clients in
//! `upstream.rs` only expose allowlisted read calls.
use crate::{
    auth::{Principal, audit, err},
    crypto,
    feed::{self, Ev},
    tenants::{Registry, TenantDb},
    upstream::{self, Shopify, Square},
};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use rusqlite::params;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

type R = Result<Response, Response>;
fn ok(v: Value) -> R {
    Ok((StatusCode::OK, Json(v)).into_response())
}

// (variant id, inventory item id, sku, clamped total, raw total), kept for the levels pass.
type PendingVariant = (String, Option<String>, Option<String>, i64, i64);
// (provider, op, requests, throttled, retries, errors, wait_ms, requests this hour).
type UsageRow = (String, String, i64, i64, i64, i64, i64, i64);

// ---------- connections ----------

fn master(reg: &Registry) -> Result<[u8; 32], Response> {
    reg.master
        .ok_or_else(|| err(503, "RUPERT_MASTER_KEY is not configured"))
}

pub async fn put_connection(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Path(provider): Path<String>,
    Json(b): Json<Value>,
) -> R {
    if p.token_id.is_some() {
        return Err(err(403, "connections are managed by signed-in owners"));
    }
    p.require("connections:write", "owner")?;
    let key = master(&reg)?;
    let creds = match provider.as_str() {
        "shopify" => {
            let (d, i, s) = (
                b["shop_domain"].as_str().unwrap_or(""),
                b["client_id"].as_str().unwrap_or(""),
                b["client_secret"].as_str().unwrap_or(""),
            );
            if !upstream::valid_shop_domain(d) {
                return Err(err(
                    400,
                    "shop_domain must look like your-store.myshopify.com",
                ));
            }
            if i.is_empty() || s.is_empty() || i.len() > 200 || s.len() > 200 {
                return Err(err(400, "client_id and client_secret are required"));
            }
            json!({ "shop_domain": d, "client_id": i, "client_secret": s })
        }
        "square" => {
            let (t, e) = (
                b["access_token"].as_str().unwrap_or(""),
                b["environment"].as_str().unwrap_or("production"),
            );
            if t.is_empty() || t.len() > 300 {
                return Err(err(400, "access_token is required"));
            }
            if e != "production" && e != "sandbox" {
                return Err(err(400, "environment must be production or sandbox"));
            }
            let (wk, wu) = (
                b["webhook_signature_key"].as_str().unwrap_or(""),
                b["webhook_url"].as_str().unwrap_or(""),
            );
            if wk.len() > 200
                || wu.len() > 300
                || (!wu.is_empty() && !wu.starts_with("https://"))
                || (wk.is_empty() != wu.is_empty())
            {
                return Err(err(
                    400,
                    "webhook_signature_key and an https webhook_url must be given together",
                ));
            }
            json!({ "access_token": t, "environment": e, "webhook_signature_key": wk, "webhook_url": wu })
        }
        _ => return Err(err(404, "unknown provider")),
    };
    let blob = crypto::seal(&key, &p.tenant_id, &provider, creds.to_string().as_bytes());
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let (r2, p2, prov) = (reg.clone(), p.clone(), provider.clone());
    tokio::task::spawn_blocking(move || {
        db.writer.lock().execute("INSERT INTO connections VALUES (?1,?2,?3) ON CONFLICT(provider) DO UPDATE SET sealed=excluded.sealed, updated_at=excluded.updated_at", params![prov, blob, crate::now()]).map_err(|_| err(500, "database error"))?;
        audit(&r2.central.lock(), Some(&p2.tenant_id), Some(p2.user_id), "connection_set", &prov);
        Ok::<(), Response>(())
    }).await.map_err(|_| err(500, "internal"))??;
    ok(json!({ "provider": provider, "connected": true }))
}

pub async fn list_connections(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    p.require("connections:read", "manager")?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let mut s = c.prepare_cached("SELECT provider,updated_at FROM connections ORDER BY provider")?;
        let v = s.query_map([], |r| Ok(json!({ "provider": r.get::<_, String>(0)?, "updated_at": r.get::<_, i64>(1)? })))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "data": rows }))
}

pub async fn delete_connection(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Path(provider): Path<String>,
) -> R {
    if p.token_id.is_some() {
        return Err(err(403, "connections are managed by signed-in owners"));
    }
    p.require("connections:write", "owner")?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let (r2, p2) = (reg.clone(), p.clone());
    let n = tokio::task::spawn_blocking(move || {
        let n = db
            .writer
            .lock()
            .execute("DELETE FROM connections WHERE provider=?1", [&provider])
            .unwrap_or(0);
        if n > 0 {
            audit(
                &r2.central.lock(),
                Some(&p2.tenant_id),
                Some(p2.user_id),
                "connection_delete",
                &provider,
            );
        }
        n
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    if n == 0 {
        Err(err(404, "not found"))
    } else {
        ok(json!({ "deleted": true }))
    }
}

// ---------- sync runs ----------

/// Start a background sync run. Shared by the manual endpoint and the scheduler.
/// Err is (http status, message).
pub async fn start_sync(
    reg: &Arc<Registry>,
    tenant: &str,
    source: &str,
) -> Result<i64, (u16, &'static str)> {
    if source != "shopify" && source != "square" {
        return Err((404, "unknown source"));
    }
    if reg.master.is_none() {
        return Err((503, "RUPERT_MASTER_KEY is not configured"));
    }
    let db = reg.db(tenant).map_err(|_| (500, "internal"))?;
    let (d2, s2) = (db.clone(), source.to_string());
    let connected = tokio::task::spawn_blocking(move || {
        d2.with_reader(|c| {
            c.query_row(
                "SELECT count(*) FROM connections WHERE provider=?1",
                [&s2],
                |r| r.get::<_, i64>(0),
            )
        })
        .unwrap_or(0)
    })
    .await
    .unwrap_or(0);
    if connected == 0 {
        return Err((409, "not connected"));
    }
    // Be kind to the provider: stop starting syncs once this tenant has used its hourly request budget.
    let (d4, s4) = (db.clone(), source.to_string());
    let used = tokio::task::spawn_blocking(move || {
        d4.with_reader(|c| {
            c.query_row(
                "SELECT coalesce(sum(requests),0) FROM api_usage WHERE provider=?1 AND bucket>?2",
                params![s4, crate::now() / BUCKET_SECS - 6],
                |r| r.get::<_, i64>(0),
            )
        })
        .unwrap_or(0)
    })
    .await
    .unwrap_or(0);
    if used >= hourly_budget() {
        return Err((
            429,
            "the hourly API request budget for this provider is used up",
        ));
    }
    let slot = (tenant.to_string(), source.to_string());
    if !reg.sync_running.lock().insert(slot.clone()) {
        return Err((409, "a sync is already running"));
    }
    let (d3, s3) = (db.clone(), source.to_string());
    let run_id = match tokio::task::spawn_blocking(move || {
        let c = d3.writer.lock();
        c.execute(
            "INSERT INTO sync_runs(source,status,started_at) VALUES (?1,'running',?2)",
            params![s3, crate::now()],
        )
        .map(|_| c.last_insert_rowid())
    })
    .await
    {
        Ok(Ok(id)) => id,
        _ => {
            reg.sync_running.lock().remove(&slot);
            return Err((500, "database error"));
        }
    };
    let r2 = reg.clone();
    let (tenant, src) = (tenant.to_string(), source.to_string());
    tokio::spawn(async move {
        // The semaphore bounds concurrent syncs process-wide, which bounds memory and upstream load.
        let _permit = r2.sync_sem.clone().acquire_owned().await;
        let (r3, t3, s3) = (r2.clone(), tenant.clone(), src.clone());
        let res = tokio::task::spawn_blocking(move || run(&r3, &t3, &s3, run_id))
            .await
            .unwrap_or_else(|_| Err("sync task panicked".into()));
        r2.sync_running
            .lock()
            .remove(&(tenant.clone(), src.clone()));
        schedule_result(&r2, &tenant, &src, res.is_ok());
    });
    Ok(run_id)
}

pub async fn trigger(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Path(source): Path<String>,
) -> R {
    p.require("sync:run", "manager")?;
    match start_sync(&reg, &p.tenant_id, &source).await {
        Ok(run_id) => Ok((
            StatusCode::ACCEPTED,
            Json(json!({ "run_id": run_id, "source": source, "status": "running" })),
        )
            .into_response()),
        Err((c, m)) => Err(err(c, m)),
    }
}

// ---------- scheduled syncs ----------

const MIN_MINUTES: i64 = 5;
const MAX_MINUTES: i64 = 1440;
const MAX_BACKOFF_SECS: i64 = 3600;

#[derive(Deserialize)]
pub struct ScheduleBody {
    source: String,
    every_minutes: Option<i64>,
    /// dev/test only
    every_seconds: Option<i64>,
}

pub async fn put_schedule(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Json(b): Json<ScheduleBody>,
) -> R {
    p.require("sync:run", "manager")?;
    if b.source != "shopify" && b.source != "square" {
        return Err(err(404, "unknown source"));
    }
    let (r2, p2) = (reg.clone(), p.clone());
    let every = match (b.every_minutes, b.every_seconds) {
        (None, None) => None, // removes the schedule
        (Some(m), _) if (MIN_MINUTES..=MAX_MINUTES).contains(&m) => Some(m * 60),
        (None, Some(sec)) if reg.auth.dev && sec >= 1 => Some(sec),
        _ => {
            return Err(err(
                400,
                &format!(
                    "every_minutes must be {MIN_MINUTES}-{MAX_MINUTES}, or null to remove the schedule"
                ),
            ));
        }
    };
    if every.is_some() {
        let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
        let s2 = b.source.clone();
        let connected = tokio::task::spawn_blocking(move || {
            db.with_reader(|c| {
                c.query_row(
                    "SELECT count(*) FROM connections WHERE provider=?1",
                    [&s2],
                    |r| r.get::<_, i64>(0),
                )
            })
            .unwrap_or(0)
        })
        .await
        .unwrap_or(0);
        if connected == 0 {
            return Err(err(409, "not connected"));
        }
    }
    let src = b.source.clone();
    tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        match every {
            Some(secs) => { let _ = c.execute("INSERT INTO schedules(tenant_id,source,every_secs,next_due,fails) VALUES (?1,?2,?3,?4,0) ON CONFLICT(tenant_id,source) DO UPDATE SET every_secs=excluded.every_secs, next_due=excluded.next_due, fails=0",
                params![p2.tenant_id, src, secs, crate::now() + secs]); audit(&c, Some(&p2.tenant_id), Some(p2.user_id), "schedule_set", &format!("{src} every {secs}s")); }
            None => { let _ = c.execute("DELETE FROM schedules WHERE tenant_id=?1 AND source=?2", params![p2.tenant_id, src]); audit(&c, Some(&p2.tenant_id), Some(p2.user_id), "schedule_delete", &src); }
        }
    }).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "source": b.source, "every_seconds": every }))
}

pub async fn get_schedule(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    p.require("inventory:read", "staff")?;
    let r2 = reg.clone();
    let rows: Vec<Value> = tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        c.prepare_cached("SELECT source,every_secs,next_due,fails FROM schedules WHERE tenant_id=?1 ORDER BY source")
            .and_then(|mut s| s.query_map([&p.tenant_id], |r| Ok(json!({ "source": r.get::<_, String>(0)?, "every_seconds": r.get::<_, i64>(1)?, "next_due": r.get::<_, i64>(2)?, "consecutive_failures": r.get::<_, i64>(3)? }))).map(|i| i.flatten().collect()))
            .unwrap_or_default()
    }).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "data": rows }))
}

/// Called when a run finishes: a success clears the failure count; a failure backs the next attempt off
/// exponentially (capped at one hour or the interval, whichever is longer).
fn schedule_result(reg: &Registry, tenant: &str, source: &str, success: bool) {
    let c = reg.central.lock();
    if success {
        let _ = c.execute(
            "UPDATE schedules SET fails=0 WHERE tenant_id=?1 AND source=?2",
            params![tenant, source],
        );
    } else if let Ok((every, fails)) = c.query_row(
        "SELECT every_secs, fails FROM schedules WHERE tenant_id=?1 AND source=?2",
        params![tenant, source],
        |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
    ) {
        let wait =
            (every.saturating_mul(1 << (fails + 1).min(10))).min(MAX_BACKOFF_SECS.max(every));
        let _ = c.execute(
            "UPDATE schedules SET fails=fails+1, next_due=?3 WHERE tenant_id=?1 AND source=?2",
            params![tenant, source, crate::now() + wait],
        );
    }
}

/// Background loop: every tick, start the syncs that are due (at most a few per tick so a restart after
/// downtime does not stampede the upstream APIs). The next attempt is scheduled before the run starts,
/// so a crash cannot cause a tight retry loop.
pub async fn scheduler(reg: Arc<Registry>) {
    let tick = std::env::var("RUPERT_SCHEDULER_TICK_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(15u64);
    let per_tick: i64 = std::env::var("RUPERT_SCHEDULER_PER_TICK")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(5);
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(tick)).await;
        let r2 = reg.clone();
        let due: Vec<(String, String)> = tokio::task::spawn_blocking(move || {
            let c = r2.central.lock();
            let now = crate::now();
            let rows: Vec<(String, String, i64)> = c.prepare_cached("SELECT tenant_id,source,every_secs FROM schedules WHERE next_due<=?1 ORDER BY next_due LIMIT ?2")
                .and_then(|mut s| s.query_map(params![now, per_tick], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).map(|i| i.flatten().collect())).unwrap_or_default();
            for (t, src, every) in &rows {
                // ~5% spread so tenants created together do not stay synchronised.
                let jitter = (t.bytes().fold(0u64, |a, b| a.wrapping_mul(31).wrapping_add(b as u64)) % (every / 20 + 1) as u64) as i64;
                let _ = c.execute("UPDATE schedules SET next_due=?3 WHERE tenant_id=?1 AND source=?2", params![t, src, now + every + jitter]);
            }
            rows.into_iter().map(|(t, s, _)| (t, s)).collect()
        }).await.unwrap_or_default();
        for (tenant, source) in due {
            if let Err((code, msg)) = start_sync(&reg, &tenant, &source).await {
                // "already running" is normal when a run outlasts its interval; anything else counts as a failure.
                if code != 409 && code != 429 {
                    schedule_result(&reg, &tenant, &source, false);
                } else {
                    let _ = msg;
                }
            }
        }
    }
}

pub async fn runs(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    p.require("inventory:read", "staff")?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let mut s = c.prepare_cached("SELECT id,source,status,started_at,finished_at,details,error FROM sync_runs ORDER BY id DESC LIMIT 50")?;
        let v = s.query_map([], |r| Ok(json!({ "id": r.get::<_, i64>(0)?, "source": r.get::<_, String>(1)?, "status": r.get::<_, String>(2)?, "started_at": r.get::<_, i64>(3)?,
            "finished_at": r.get::<_, Option<i64>>(4)?, "details": r.get::<_, Option<String>>(5)?.and_then(|d| serde_json::from_str::<Value>(&d).ok()), "error": r.get::<_, Option<String>>(6)? })))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "data": rows }))
}

pub(crate) fn publish(db: &TenantDb, evs: Vec<Ev>) {
    db.publish(evs);
}

pub(crate) fn env_u64(k: &str, d: u64) -> u64 {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
}

/// Per-run request cap. A normal full sync needs roughly (variants / 30) + a handful of calls, so this
/// leaves room for very large catalogs while still stopping a loop within seconds.
pub(crate) fn run_cap() -> u64 {
    env_u64("RUPERT_MAX_REQUESTS_PER_RUN", 5000)
}
/// Requests per provider per rolling hour before new syncs are refused.
pub(crate) fn hourly_budget() -> i64 {
    env_u64("RUPERT_API_BUDGET_PER_HOUR", 1000) as i64
}
pub(crate) const BUCKET_SECS: i64 = 600;

pub(crate) fn record_usage(db: &TenantDb, source: &str, meter: &upstream::SharedMeter) {
    let m = meter.lock();
    let bucket = crate::now() / BUCKET_SECS;
    let c = db.writer.lock();
    for (op, o) in m.ops.iter() {
        let _ = c.execute("INSERT INTO api_usage VALUES (?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(bucket,provider,op) DO UPDATE SET requests=requests+excluded.requests, throttled=throttled+excluded.throttled, retries=retries+excluded.retries, errors=errors+excluded.errors, wait_ms=wait_ms+excluded.wait_ms",
            params![bucket, source, op, o.requests as i64, o.throttled as i64, o.retries as i64, o.errors as i64, o.wait_ms as i64]);
    }
    let _ = c.execute(
        "DELETE FROM api_usage WHERE bucket < ?1",
        [bucket - 30 * 144],
    ); // keep 30 days
}

/// Decrypts the stored credentials for one provider.
pub(crate) fn load_creds(
    reg: &Registry,
    db: &TenantDb,
    tenant: &str,
    source: &str,
) -> Result<Value, String> {
    let key = reg.master.ok_or("RUPERT_MASTER_KEY is not configured")?;
    let blob: Vec<u8> = db
        .with_reader(|c| {
            c.query_row(
                "SELECT sealed FROM connections WHERE provider=?1",
                [source],
                |r| r.get(0),
            )
        })
        .map_err(|_| "not connected".to_string())?;
    serde_json::from_slice(
        &crypto::open(&key, tenant, source, &blob)
            .ok_or("stored credentials could not be decrypted")?,
    )
    .map_err(|_| "stored credentials are corrupt".to_string())
}

fn dev_env(reg: &Registry, k: &str) -> Option<String> {
    if reg.auth.dev {
        std::env::var(k).ok()
    } else {
        None
    }
} // test upstreams only in dev mode

pub(crate) fn make_shopify(reg: &Registry, creds: &Value, meter: upstream::SharedMeter) -> Shopify {
    let base = dev_env(reg, "RUPERT_SHOPIFY_BASE").unwrap_or_else(|| {
        format!(
            "https://{}",
            creds["shop_domain"].as_str().unwrap_or_default()
        )
    });
    Shopify::new(
        base,
        creds["client_id"].as_str().unwrap_or_default().into(),
        creds["client_secret"].as_str().unwrap_or_default().into(),
        meter,
    )
}

pub(crate) fn make_square(reg: &Registry, creds: &Value, meter: upstream::SharedMeter) -> Square {
    let base = dev_env(reg, "RUPERT_SQUARE_BASE").unwrap_or_else(|| {
        if creds["environment"] == "sandbox" {
            "https://connect.squareupsandbox.com/v2".into()
        } else {
            "https://connect.squareup.com/v2".into()
        }
    });
    Square::new(
        base,
        creds["access_token"].as_str().unwrap_or_default().into(),
        meter,
    )
}

fn run(reg: &Registry, tenant: &str, source: &str, run_id: i64) -> Result<Value, String> {
    let db = reg.db(tenant).map_err(|e| e.to_string())?;
    let meter = upstream::Meter::shared(run_cap());
    let result = (|| {
        let creds = load_creds(reg, &db, tenant, source)?;
        match source {
            "shopify" => sync_shopify(&db, run_id, &mut make_shopify(reg, &creds, meter.clone())),
            _ => sync_square(&db, run_id, make_square(reg, &creds, meter.clone())),
        }
    })();
    // Every run, successful or not, records how many calls it made (also kept per hour for budgeting).
    let api = meter.lock().snapshot();
    record_usage(&db, source, &meter);
    let result = result.map(|mut d| {
        d["api"] = api.clone();
        d
    });
    let (status, details, error) = match &result {
        Ok(d) => ("ok", Some(d.to_string()), None),
        Err(e) => (
            "failed",
            Some(json!({ "api": api }).to_string()),
            Some(e.chars().take(500).collect::<String>()),
        ),
    };
    let mut evs = Vec::new();
    {
        let mut c = db.writer.lock();
        if let Ok(tx) = c.transaction() {
            let _ = tx.execute(
                "UPDATE sync_runs SET status=?2, finished_at=?3, details=?4, error=?5 WHERE id=?1",
                params![run_id, status, crate::now(), details, error],
            );
            if let Ok(Some(e)) = feed::emit_if(
                db.realtime(),
                &tx,
                "sync.finished",
                Some(source),
                &json!({ "run_id": run_id, "status": status, "error": error }),
            ) {
                evs.push(e);
            }
            feed::prune(&tx, 10_000);
            let _ = tx.commit();
        }
    }
    publish(&db, evs);
    result
}

// ---------- orders (read-only mirror; no customer identity, address or payment details) ----------

/// ISO-8601 UTC timestamp from epoch seconds (civil-from-days, no date crate).
fn iso(secs: i64) -> String {
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y + (m <= 2) as i64,
        m,
        d,
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Where the next order pass starts: the last good pass's start minus a day of overlap (catches edits that
/// land while a pass runs), or `RUPERT_ORDER_LOOKBACK_DAYS` (default 30) back on the first pass.
fn orders_since(db: &TenantDb, source: &str) -> (String, bool) {
    let last: Option<i64> = db
        .with_reader(|c| {
            c.query_row(
                "SELECT value FROM settings WHERE key=?1",
                [format!("orders_since_{source}")],
                |r| r.get::<_, String>(0),
            )
        })
        .ok()
        .and_then(|v| v.parse().ok());
    let lookback = env_u64("RUPERT_ORDER_LOOKBACK_DAYS", 30) as i64 * 86400;
    match last {
        Some(t) => (iso(t - 86400), false),
        None => (iso(crate::now() - lookback), true),
    }
}

fn set_orders_watermark(db: &TenantDb, source: &str, started: i64) {
    let _ = db.writer.lock().execute(
        "INSERT INTO settings VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![format!("orders_since_{source}"), started.to_string()],
    );
}

/// Upserts a page of orders (replacing each order's lines). `silent` suppresses events for the first backfill.
pub fn ingest_orders(
    db: &TenantDb,
    source: &str,
    run_id: i64,
    page: &[upstream::Order],
    silent: bool,
) -> Result<(i64, i64), String> {
    let (mut added, mut changed) = (0i64, 0i64);
    let mut evs = Vec::new();
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        for o in page {
            let old: Option<(Option<String>, Option<String>, Option<String>)> = tx
                .prepare_cached("SELECT updated_at,status,cancelled_at FROM orders WHERE id=?1")
                .and_then(|mut s| s.query_row([&o.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))))
                .ok();
            let same = old.as_ref().is_some_and(|(u, st, ca)| {
                *u == o.updated_at && *st == o.status && *ca == o.cancelled_at
            });
            if same {
                tx.execute(
                    "UPDATE orders SET synced_run=?2 WHERE id=?1",
                    params![o.id, run_id],
                )
                .map_err(|e| e.to_string())?;
                continue;
            }
            tx.prepare_cached("INSERT INTO orders(id,source,name,created_at,updated_at,cancelled_at,status,total,currency,line_count,synced_run) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,updated_at=excluded.updated_at,cancelled_at=excluded.cancelled_at,status=excluded.status,total=excluded.total,currency=excluded.currency,line_count=excluded.line_count,synced_run=excluded.synced_run")
                .and_then(|mut s| s.execute(params![o.id, source, o.name, o.created_at, o.updated_at, o.cancelled_at, o.status, o.total, o.currency, o.lines.len() as i64, run_id])).map_err(|e| e.to_string())?;
            tx.execute("DELETE FROM order_lines WHERE order_id=?1", [&o.id])
                .map_err(|e| e.to_string())?;
            for l in &o.lines {
                // Square lines only carry the catalog variation id; resolve the SKU from the mirrored catalog.
                let sku = l.sku.clone().or_else(|| {
                    l.variant_id.as_ref().and_then(|v| {
                        let q = if source == "shopify" {
                            "SELECT sku FROM shopify_variants WHERE id=?1"
                        } else {
                            "SELECT sku FROM square_variations WHERE id=?1"
                        };
                        tx.query_row(q, [v], |r| r.get::<_, Option<String>>(0))
                            .ok()
                            .flatten()
                    })
                });
                tx.prepare_cached(
                    "INSERT OR REPLACE INTO order_lines VALUES (?1,?2,?3,?4,?5,?6,?7)",
                )
                .and_then(|mut s| {
                    s.execute(params![
                        o.id,
                        l.line_id,
                        sku,
                        l.variant_id,
                        l.title,
                        l.qty,
                        l.price
                    ])
                })
                .map_err(|e| e.to_string())?;
            }
            if old.is_none() {
                added += 1
            } else {
                changed += 1
            }
            if !silent {
                let kind = if old.is_none() {
                    "mirror.order.added"
                } else {
                    "mirror.order.changed"
                };
                evs.extend(feed::emit_if(db.realtime(), &tx, kind, Some(&o.id), &json!({ "source": source, "name": o.name, "status": o.status, "total": o.total, "currency": o.currency, "lines": o.lines.len() })).map_err(|e| e.to_string())?);
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    Ok((added, changed))
}

fn orders_enabled() -> bool {
    std::env::var("RUPERT_ORDERS").as_deref() != Ok("0")
}

fn orders_phase(r: Result<Value, String>) -> Result<Value, String> {
    match r {
        Ok(v) => Ok(v),
        // A hit request cap means something is looping: that must fail the run. Anything else (typically a token
        // without the orders scope) is reported in the run details and must not break the catalog sync.
        Err(e) if e.contains("request cap") => Err(e),
        Err(e) => Ok(json!({ "error": e.chars().take(300).collect::<String>() })),
    }
}

fn sync_orders_shopify(db: &TenantDb, run_id: i64, client: &mut Shopify) -> Result<Value, String> {
    let started = crate::now();
    let (since, initial) = orders_since(db, "shopify");
    let (mut seen, mut added, mut changed) = (0i64, 0i64, 0i64);
    client.orders(&since, |page| {
        seen += page.len() as i64;
        let (a, c) = ingest_orders(db, "shopify", run_id, &page, initial)?;
        added += a;
        changed += c;
        Ok(())
    })?;
    set_orders_watermark(db, "shopify", started);
    Ok(json!({ "since": since, "seen": seen, "added": added, "changed": changed }))
}

fn sync_orders_square(
    db: &TenantDb,
    run_id: i64,
    client: &Square,
    locations: &[String],
) -> Result<Value, String> {
    let started = crate::now();
    let (since, initial) = orders_since(db, "square");
    let (mut seen, mut added, mut changed) = (0i64, 0i64, 0i64);
    client.orders(locations, &since, |page| {
        seen += page.len() as i64;
        let (a, c) = ingest_orders(db, "square", run_id, &page, initial)?;
        added += a;
        changed += c;
        Ok(())
    })?;
    set_orders_watermark(db, "square", started);
    Ok(json!({ "since": since, "seen": seen, "added": added, "changed": changed }))
}

// ---------- Shopify ingest ----------

fn sync_shopify(db: &TenantDb, run_id: i64, client: &mut Shopify) -> Result<Value, String> {
    // Locations first: levels reference them, and one of them is flagged primary (first active, else first).
    let mut locs = client.locations()?;
    if locs.is_empty() {
        locs.push(upstream::ShopLocation {
            id: "default".into(),
            name: "Shopify Online Store".into(),
            active: true,
        });
    }
    let primary = locs
        .iter()
        .find(|l| l.active)
        .or(locs.first())
        .map(|l| l.id.clone());
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        for l in &locs {
            tx.execute("INSERT INTO shopify_locations(id,name,active,is_primary,synced_run) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET name=excluded.name,active=excluded.active,is_primary=excluded.is_primary,synced_run=excluded.synced_run",
                params![l.id, l.name, l.active, Some(&l.id) == primary.as_ref(), run_id]).map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    let (mut seen, mut added, mut changed, mut oversold) = (0i64, 0i64, 0i64, 0i64);
    // (variant id, inventory item id, sku, clamped total, raw total) kept for the levels pass.
    let mut pending: Vec<PendingVariant> = Vec::new();
    client.variants(|page| {
        let mut evs = Vec::new();
        {
            let mut c = db.writer.lock();
            let tx = c.transaction().map_err(|e| e.to_string())?;
            for v in &page {
                seen += 1;
                // Same rule as the Rails mirror: oversold (negative) stock is stored as 0 and counted.
                if v.qty < 0 && v.tracked { oversold += 1; }
                let qty_in = v.qty.max(0);
                pending.push((v.id.clone(), v.inventory_item_id.clone(), v.sku.clone(), qty_in, v.qty));
                let old: Option<(String, Option<String>, Option<f64>, i64)> = tx.prepare_cached("SELECT title,sku,price,qty FROM shopify_variants WHERE id=?1").and_then(|mut s| s.query_row([&v.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))).ok();
                tx.prepare_cached("INSERT INTO shopify_variants(id,product_id,title,sku,price,inventory_item_id,qty,tracked,synced_run,product_status) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
                    ON CONFLICT(id) DO UPDATE SET product_status=excluded.product_status,product_id=excluded.product_id,title=excluded.title,sku=excluded.sku,price=excluded.price,inventory_item_id=excluded.inventory_item_id,qty=excluded.qty,tracked=excluded.tracked,synced_run=excluded.synced_run")
                    .and_then(|mut s| s.execute(params![v.id, v.product_id, v.title, v.sku, v.price, v.inventory_item_id, qty_in, v.tracked, run_id, v.product_status])).map_err(|e| e.to_string())?;
                match old {
                    None => { added += 1; evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.added", Some(&v.id), &json!({ "source": "shopify", "sku": v.sku, "title": v.title, "qty": qty_in })).map_err(|e| e.to_string())?); }
                    Some((t, sku, price, qty)) if t != v.title || sku != v.sku || price != v.price || qty != qty_in => {
                        changed += 1;
                        evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.changed", Some(&v.id), &json!({ "source": "shopify", "sku": v.sku, "qty": { "from": qty, "to": qty_in }, "price": { "from": price, "to": v.price }, "title_changed": t != v.title, "sku_changed": sku != v.sku })).map_err(|e| e.to_string())?);
                    }
                    _ => {}
                }
            }
            tx.commit().map_err(|e| e.to_string())?;
        }
        publish(db, evs);
        Ok(())
    })?;
    // Never mirror an empty catalog over a populated one: a bad token scope or outage
    // must not wipe the local copy.
    let existing: i64 = db
        .with_reader(|c| c.query_row("SELECT count(*) FROM shopify_variants", [], |r| r.get(0)))
        .unwrap_or(0);
    if seen == 0 && existing > 0 {
        return Err("Shopify returned no variants; refusing to remove the existing mirror".into());
    }

    // Per-location levels, same rules as the Rails mirror: "available" clamped at 0 per location; a variant
    // with no level data keeps its total on the primary location so it still shows up.
    let known: std::collections::HashSet<&str> = locs.iter().map(|l| l.id.as_str()).collect();
    let (mut level_rows, mut level_changes) = (0i64, 0i64);
    for group in pending.chunks(150) {
        let ids: Vec<String> = group
            .iter()
            .filter_map(|g| g.1.clone())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();
        let by_item = if ids.is_empty() {
            Default::default()
        } else {
            client.levels(&ids)?
        };
        let mut evs = Vec::new();
        {
            let mut c = db.writer.lock();
            let tx = c.transaction().map_err(|e| e.to_string())?;
            for (vid, item, sku, total, raw_total) in group {
                let mut rows: Vec<(String, i64, i64)> = Vec::new();
                match item
                    .as_ref()
                    .and_then(|i| by_item.get(i))
                    .filter(|l| !l.is_empty())
                {
                    Some(levels) => {
                        for (loc, avail) in levels {
                            if known.contains(loc.as_str()) {
                                rows.push((loc.clone(), (*avail).max(0), *avail));
                            }
                        }
                    }
                    None => {
                        if let Some(p) = &primary {
                            rows.push((p.clone(), *total, *raw_total));
                        }
                    }
                }
                for (loc, qty, raw) in rows {
                    level_rows += 1;
                    let old: Option<i64> = tx
                        .prepare_cached(
                            "SELECT qty FROM shopify_levels WHERE variant_id=?1 AND location_id=?2",
                        )
                        .and_then(|mut s| s.query_row(params![vid, loc], |r| r.get(0)))
                        .ok();
                    tx.prepare_cached("INSERT INTO shopify_levels(variant_id,location_id,qty,raw_qty,synced_run) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(variant_id,location_id) DO UPDATE SET qty=excluded.qty,raw_qty=excluded.raw_qty,synced_run=excluded.synced_run")
                        .and_then(|mut s| s.execute(params![vid, loc, qty, raw, run_id])).map_err(|e| e.to_string())?;
                    // New rows are covered by mirror.variant.added; only real changes to known rows are events.
                    if let Some(o) = old.filter(|o| *o != qty) {
                        level_changes += 1;
                        evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.level.changed", Some(vid), &json!({ "source": "shopify", "sku": sku, "location_id": loc, "qty": { "from": o, "to": qty } })).map_err(|e| e.to_string())?);
                    }
                }
            }
            tx.commit().map_err(|e| e.to_string())?;
        }
        publish(db, evs);
    }
    {
        let c = db.writer.lock();
        c.execute("DELETE FROM shopify_levels WHERE synced_run<>?1", [run_id])
            .map_err(|e| e.to_string())?;
        c.execute(
            "DELETE FROM shopify_locations WHERE synced_run<>?1",
            [run_id],
        )
        .map_err(|e| e.to_string())?;
    }
    let removed = remove_stale(db, "shopify_variants", "shopify", run_id)?;
    let orders = if orders_enabled() {
        orders_phase(sync_orders_shopify(db, run_id, client))?
    } else {
        json!({ "skipped": true })
    };
    Ok(
        json!({ "seen": seen, "added": added, "changed": changed, "removed": removed, "oversold": oversold, "locations": locs.len(), "levels": level_rows, "level_changes": level_changes, "orders": orders }),
    )
}

fn remove_stale(db: &TenantDb, table: &str, source: &str, run_id: i64) -> Result<i64, String> {
    let mut evs = Vec::new();
    let n;
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        let stale: Vec<(String, Option<String>)> = tx
            .prepare(&format!("SELECT id,sku FROM {table} WHERE synced_run<>?1"))
            .and_then(|mut s| {
                s.query_map([run_id], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map(|i| i.flatten().collect())
            })
            .map_err(|e| e.to_string())?;
        n = stale.len() as i64;
        for (id, sku) in &stale {
            evs.extend(
                feed::emit_if(
                    db.realtime(),
                    &tx,
                    "mirror.variant.removed",
                    Some(id),
                    &json!({ "source": source, "sku": sku }),
                )
                .map_err(|e| e.to_string())?,
            );
        }
        tx.execute(
            &format!("DELETE FROM {table} WHERE synced_run<>?1"),
            [run_id],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    Ok(n)
}

// ---------- Square ingest ----------

fn sync_square(db: &TenantDb, run_id: i64, client: Square) -> Result<Value, String> {
    let loc_pairs = client.locations()?;
    if loc_pairs.is_empty() {
        return Err("Square returned no active locations".into());
    }
    let locations: Vec<String> = loc_pairs.iter().map(|(id, _)| id.clone()).collect();
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        for (id, name) in &loc_pairs {
            tx.execute("INSERT INTO square_locations VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET name=excluded.name, synced_run=excluded.synced_run", params![id, name, run_id]).map_err(|e| e.to_string())?;
        }
        tx.execute(
            "DELETE FROM square_locations WHERE synced_run<>?1",
            [run_id],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    let (mut seen, mut added) = (0i64, 0i64);
    let mut ids: Vec<String> = Vec::new();
    client.catalog(|page| {
        let mut evs = Vec::new();
        {
            let mut c = db.writer.lock();
            let tx = c.transaction().map_err(|e| e.to_string())?;
            for v in &page {
                seen += 1;
                ids.push(v.id.clone());
                let existed = tx.prepare_cached("SELECT 1 FROM square_variations WHERE id=?1").and_then(|mut s| s.exists([&v.id])).unwrap_or(false);
                // qty is left untouched here; counts below own it.
                tx.prepare_cached("INSERT INTO square_variations(id,item_id,name,sku,qty,synced_run) VALUES (?1,?2,?3,?4,0,?5)
                    ON CONFLICT(id) DO UPDATE SET item_id=excluded.item_id,name=excluded.name,sku=excluded.sku,synced_run=excluded.synced_run")
                    .and_then(|mut s| s.execute(params![v.id, v.item_id, v.name, v.sku, run_id])).map_err(|e| e.to_string())?;
                if !existed { added += 1; evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.added", Some(&v.id), &json!({ "source": "square", "sku": v.sku, "title": v.name })).map_err(|e| e.to_string())?); }
            }
            tx.commit().map_err(|e| e.to_string())?;
        }
        publish(db, evs);
        Ok(())
    })?;
    let existing: i64 = db
        .with_reader(|c| c.query_row("SELECT count(*) FROM square_variations", [], |r| r.get(0)))
        .unwrap_or(0);
    if seen == 0 && existing > 0 {
        return Err("Square returned no variations; refusing to remove the existing mirror".into());
    }
    for chunk in ids.chunks(100) {
        let counts = client.counts(&locations, chunk)?;
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        for (var, loc, q) in counts {
            tx.prepare_cached("INSERT INTO square_counts VALUES (?1,?2,?3,?4) ON CONFLICT(variation_id,location_id) DO UPDATE SET qty=excluded.qty, synced_run=excluded.synced_run")
                .and_then(|mut s| s.execute(params![var, loc, q, run_id])).map_err(|e| e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    // Totals: a variation with no count this run is out of stock everywhere (0), not "unknown".
    let mut evs = Vec::new();
    let mut changed = 0i64;
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        let diffs: Vec<(String, Option<String>, i64, i64)> = tx.prepare(
            "SELECT v.id, v.sku, v.qty, coalesce(s.t,0) FROM square_variations v
             LEFT JOIN (SELECT variation_id, sum(qty) t FROM square_counts WHERE synced_run=?1 GROUP BY variation_id) s ON s.variation_id=v.id
             WHERE v.synced_run=?1 AND v.qty <> coalesce(s.t,0)").and_then(|mut s| s.query_map([run_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).map(|i| i.flatten().collect())).map_err(|e| e.to_string())?;
        for (id, sku, from, to) in diffs {
            tx.execute(
                "UPDATE square_variations SET qty=?2 WHERE id=?1",
                params![id, to],
            )
            .map_err(|e| e.to_string())?;
            changed += 1;
            evs.extend(
                feed::emit_if(
                    db.realtime(),
                    &tx,
                    "mirror.variant.changed",
                    Some(&id),
                    &json!({ "source": "square", "sku": sku, "qty": { "from": from, "to": to } }),
                )
                .map_err(|e| e.to_string())?,
            );
        }
        tx.execute("DELETE FROM square_counts WHERE synced_run<>?1", [run_id])
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    let removed = remove_stale(db, "square_variations", "square", run_id)?;
    let orders = if orders_enabled() {
        orders_phase(sync_orders_square(db, run_id, &client, &locations))?
    } else {
        json!({ "skipped": true })
    };
    Ok(
        json!({ "seen": seen, "added": added, "changed": changed, "removed": removed, "locations": locations.len(), "orders": orders }),
    )
}

// ---------- mirror reads (shape follows docs/api-v1.md) ----------

#[derive(Deserialize)]
pub struct ListQ {
    source: Option<String>,
    page: Option<i64>,
    per_page: Option<i64>,
}

fn page_params(q: &ListQ) -> Result<(String, i64, i64), Response> {
    let source = q.source.clone().unwrap_or_else(|| "shopify".into());
    if source != "shopify" && source != "square" {
        return Err(err(400, "source must be shopify or square"));
    }
    let (page, per) = (q.page.unwrap_or(1), q.per_page.unwrap_or(50));
    if !(1..=1000).contains(&page) || !(1..=100).contains(&per) {
        return Err(err(400, "page must be 1-1000 and per_page 1-100"));
    }
    Ok((source, page, per))
}

async fn list(reg: Arc<Registry>, p: Principal, scope: &str, q: ListQ, inventory: bool) -> R {
    p.require(scope, "staff")?;
    let (source, page, per) = page_params(&q)?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let src = source.clone();
    let mut rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let sql = match (src.as_str(), inventory) {
            ("shopify", false) => "SELECT id,sku,title,product_id,price,qty,product_status FROM shopify_variants ORDER BY id LIMIT ?1 OFFSET ?2",
            ("shopify", true) => "SELECT id,sku,title,product_id,price,qty FROM shopify_variants ORDER BY id LIMIT ?1 OFFSET ?2",
            (_, false) => "SELECT id,sku,name,item_id,NULL,qty FROM square_variations ORDER BY id LIMIT ?1 OFFSET ?2",
            (_, true) => "SELECT id,sku,name,item_id,NULL,qty FROM square_variations ORDER BY id LIMIT ?1 OFFSET ?2",
        };
        let mut s = c.prepare_cached(sql)?;
        let v = s.query_map((per + 1, (page - 1) * per), |r| {
            Ok(if inventory { json!({ "id": r.get::<_, String>(0)?, "source": src, "sku": r.get::<_, Option<String>>(1)?, "quantity": r.get::<_, i64>(5)? }) }
               else { json!({ "id": r.get::<_, String>(0)?, "source": src, "sku": r.get::<_, Option<String>>(1)?, "name": r.get::<_, String>(2)?, "product_id": r.get::<_, String>(3)?, "price": r.get::<_, Option<f64>>(4)?, "status": r.get::<_, Option<String>>(6).unwrap_or(None) }) })
        })?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    let has_more = rows.len() as i64 > per && page < 1000;
    rows.truncate(per as usize);
    ok(
        json!({ "data": rows, "meta": { "page": page, "per_page": per, "has_more": has_more, "next_page": has_more.then_some(page + 1) } }),
    )
}

pub async fn catalog(State(reg): State<Arc<Registry>>, p: Principal, Query(q): Query<ListQ>) -> R {
    list(reg, p, "catalog:read", q, false).await
}
pub async fn inventory(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Query(q): Query<ListQ>,
) -> R {
    list(reg, p, "inventory:read", q, true).await
}

// ---------- locations and per-location levels ----------

pub async fn locations(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Query(q): Query<ListQ>,
) -> R {
    p.require("inventory:read", "staff")?;
    let source = q.source.clone().unwrap_or_else(|| "shopify".into());
    if source != "shopify" && source != "square" {
        return Err(err(400, "source must be shopify or square"));
    }
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let src = source.clone();
    let rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        if src == "shopify" {
            let mut s = c.prepare_cached("SELECT id,name,active,is_primary FROM shopify_locations ORDER BY name,id")?;
            let v = s.query_map([], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "source": "shopify", "name": r.get::<_, String>(1)?, "active": r.get::<_, bool>(2)?, "primary": r.get::<_, bool>(3)? })))?.flatten().collect();
            Ok(v)
        } else {
            let mut s = c.prepare_cached("SELECT id,name FROM square_locations ORDER BY name,id")?;
            let v = s.query_map([], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "source": "square", "name": r.get::<_, String>(1)?, "active": true })))?.flatten().collect();
            Ok(v)
        }
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "data": rows }))
}

pub async fn levels(State(reg): State<Arc<Registry>>, p: Principal, Query(q): Query<ListQ>) -> R {
    p.require("inventory:read", "staff")?;
    let (source, page, per) = page_params(&q)?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let src = source.clone();
    let mut rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let sql = if src == "shopify" {
            "SELECT l.variant_id,v.sku,l.location_id,l.qty FROM shopify_levels l LEFT JOIN shopify_variants v ON v.id=l.variant_id ORDER BY l.variant_id,l.location_id LIMIT ?1 OFFSET ?2"
        } else {
            "SELECT c.variation_id,v.sku,c.location_id,c.qty FROM square_counts c LEFT JOIN square_variations v ON v.id=c.variation_id ORDER BY c.variation_id,c.location_id LIMIT ?1 OFFSET ?2"
        };
        let mut s = c.prepare_cached(sql)?;
        let v = s.query_map((per + 1, (page - 1) * per), |r| Ok(json!({ "variant_id": r.get::<_, String>(0)?, "source": src, "sku": r.get::<_, Option<String>>(1)?, "location_id": r.get::<_, String>(2)?, "quantity": r.get::<_, i64>(3)? })))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    let has_more = rows.len() as i64 > per && page < 1000;
    rows.truncate(per as usize);
    ok(
        json!({ "data": rows, "meta": { "page": page, "per_page": per, "has_more": has_more, "next_page": has_more.then_some(page + 1) } }),
    )
}

// ---------- API usage ----------

#[derive(Deserialize)]
pub struct UsageQ {
    hours: Option<i64>,
}

/// How many calls we made to each provider (and how many were throttled or retried), so over-eager loops
/// are visible. `last_hour` is what the hourly budget is measured against.
pub async fn usage(State(reg): State<Arc<Registry>>, p: Principal, Query(q): Query<UsageQ>) -> R {
    p.require("inventory:read", "staff")?;
    let hours = q.hours.unwrap_or(24).clamp(1, 720);
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let rows: Vec<UsageRow> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let since = crate::now() / BUCKET_SECS - hours * 6;
        let mut s = c.prepare_cached("SELECT provider,op,sum(requests),sum(throttled),sum(retries),sum(errors),sum(wait_ms),sum(CASE WHEN bucket>?2 THEN requests ELSE 0 END) FROM api_usage WHERE bucket>?1 GROUP BY provider,op ORDER BY provider,op")?;
        let v = s.query_map(params![since, crate::now() / BUCKET_SECS - 6], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?)))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    let mut out = serde_json::Map::new();
    for (prov, op, req, thr, ret, errs, wait, last) in rows {
        let e = out.entry(prov).or_insert_with(|| json!({ "requests": 0, "throttled": 0, "retries": 0, "errors": 0, "wait_ms": 0, "last_hour": 0, "by_op": {} }));
        for (k, v) in [
            ("requests", req),
            ("throttled", thr),
            ("retries", ret),
            ("errors", errs),
            ("wait_ms", wait),
            ("last_hour", last),
        ] {
            e[k] = json!(e[k].as_i64().unwrap_or(0) + v);
        }
        e["by_op"][op] = json!(req);
    }
    ok(
        json!({ "hours": hours, "hourly_budget": hourly_budget(), "per_run_cap": run_cap(), "providers": out }),
    )
}

// ---------- order reads ----------

#[derive(Deserialize)]
pub struct OrdersQ {
    source: Option<String>,
    since: Option<String>,
    id: Option<String>,
    page: Option<i64>,
    per_page: Option<i64>,
}

pub async fn orders_list(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Query(q): Query<OrdersQ>,
) -> R {
    p.require("orders:read", "manager")?;
    let (page, per) = (q.page.unwrap_or(1), q.per_page.unwrap_or(50));
    if !(1..=1000).contains(&page) || !(1..=100).contains(&per) {
        return Err(err(400, "page must be 1-1000 and per_page 1-100"));
    }
    let source = q.source.clone().filter(|s| s == "shopify" || s == "square");
    if q.source.is_some() && source.is_none() {
        return Err(err(400, "source must be shopify or square"));
    }
    let since = q.since.clone().unwrap_or_default();
    if since.len() > 30 {
        return Err(err(400, "invalid since"));
    }
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let mut rows: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let mut s = c.prepare_cached("SELECT id,source,name,created_at,updated_at,cancelled_at,status,total,currency,line_count FROM orders WHERE (?1 IS NULL OR source=?1) AND created_at>=?2 ORDER BY created_at DESC, id LIMIT ?3 OFFSET ?4")?;
        let v = s.query_map(params![source, since, per + 1, (page - 1) * per], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "source": r.get::<_, String>(1)?, "name": r.get::<_, Option<String>>(2)?,
            "created_at": r.get::<_, String>(3)?, "updated_at": r.get::<_, Option<String>>(4)?, "cancelled_at": r.get::<_, Option<String>>(5)?, "status": r.get::<_, Option<String>>(6)?,
            "total": r.get::<_, Option<f64>>(7)?, "currency": r.get::<_, Option<String>>(8)?, "line_count": r.get::<_, i64>(9)? })))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    let has_more = rows.len() as i64 > per && page < 1000;
    rows.truncate(per as usize);
    ok(
        json!({ "data": rows, "meta": { "page": page, "per_page": per, "has_more": has_more, "next_page": has_more.then_some(page + 1) } }),
    )
}

/// One order with its lines. The id goes in the query string because Shopify ids contain slashes.
pub async fn order_detail(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Query(q): Query<OrdersQ>,
) -> R {
    p.require("orders:read", "manager")?;
    let id =
        q.id.clone()
            .filter(|i| !i.is_empty() && i.len() <= 100)
            .ok_or_else(|| err(400, "id is required"))?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let found = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let head = c.query_row("SELECT id,source,name,created_at,updated_at,cancelled_at,status,total,currency FROM orders WHERE id=?1", [&id], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "source": r.get::<_, String>(1)?, "name": r.get::<_, Option<String>>(2)?,
            "created_at": r.get::<_, String>(3)?, "updated_at": r.get::<_, Option<String>>(4)?, "cancelled_at": r.get::<_, Option<String>>(5)?, "status": r.get::<_, Option<String>>(6)?, "total": r.get::<_, Option<f64>>(7)?, "currency": r.get::<_, Option<String>>(8)? })))?;
        let mut s = c.prepare_cached("SELECT line_id,sku,variant_id,title,qty,price FROM order_lines WHERE order_id=?1 ORDER BY line_id")?;
        let lines: Vec<Value> = s.query_map([&id], |r| Ok(json!({ "line_id": r.get::<_, String>(0)?, "sku": r.get::<_, Option<String>>(1)?, "variant_id": r.get::<_, Option<String>>(2)?, "title": r.get::<_, String>(3)?, "quantity": r.get::<_, i64>(4)?, "price": r.get::<_, Option<f64>>(5)? })))?.flatten().collect();
        Ok::<Value, rusqlite::Error>(json!({ "order": head, "lines": lines }))
    }).ok()).await.map_err(|_| err(500, "internal"))?;
    match found {
        Some(v) => ok(v),
        None => Err(err(404, "not found")),
    }
}
