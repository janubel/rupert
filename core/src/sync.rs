//! Read-only mirror sync (Shopify, Square), sealed provider connections, and the
//! mirror read endpoints. Nothing here writes to Shopify or Square: the clients in
//! `upstream.rs` only expose allowlisted read calls.
use crate::{auth::{Principal, audit, err}, crypto, feed::{self, Ev}, tenants::{Registry, TenantDb}, upstream::{self, Shopify, Square}};
use axum::{Json, extract::{Path, Query, State}, http::StatusCode, response::{IntoResponse, Response}};
use rusqlite::params;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

type R = Result<Response, Response>;
fn ok(v: Value) -> R { Ok((StatusCode::OK, Json(v)).into_response()) }

// ---------- connections ----------

fn master(reg: &Registry) -> Result<[u8; 32], Response> { reg.master.ok_or_else(|| err(503, "RUPERT_MASTER_KEY is not configured")) }

pub async fn put_connection(State(reg): State<Arc<Registry>>, p: Principal, Path(provider): Path<String>, Json(b): Json<Value>) -> R {
    if p.token_id.is_some() { return Err(err(403, "connections are managed by signed-in owners")); }
    p.require("connections:write", "owner")?;
    let key = master(&reg)?;
    let creds = match provider.as_str() {
        "shopify" => {
            let (d, i, s) = (b["shop_domain"].as_str().unwrap_or(""), b["client_id"].as_str().unwrap_or(""), b["client_secret"].as_str().unwrap_or(""));
            if !upstream::valid_shop_domain(d) { return Err(err(400, "shop_domain must look like your-store.myshopify.com")); }
            if i.is_empty() || s.is_empty() || i.len() > 200 || s.len() > 200 { return Err(err(400, "client_id and client_secret are required")); }
            json!({ "shop_domain": d, "client_id": i, "client_secret": s })
        }
        "square" => {
            let (t, e) = (b["access_token"].as_str().unwrap_or(""), b["environment"].as_str().unwrap_or("production"));
            if t.is_empty() || t.len() > 300 { return Err(err(400, "access_token is required")); }
            if e != "production" && e != "sandbox" { return Err(err(400, "environment must be production or sandbox")); }
            json!({ "access_token": t, "environment": e })
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

pub async fn delete_connection(State(reg): State<Arc<Registry>>, p: Principal, Path(provider): Path<String>) -> R {
    if p.token_id.is_some() { return Err(err(403, "connections are managed by signed-in owners")); }
    p.require("connections:write", "owner")?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let (r2, p2) = (reg.clone(), p.clone());
    let n = tokio::task::spawn_blocking(move || {
        let n = db.writer.lock().execute("DELETE FROM connections WHERE provider=?1", [&provider]).unwrap_or(0);
        if n > 0 { audit(&r2.central.lock(), Some(&p2.tenant_id), Some(p2.user_id), "connection_delete", &provider); }
        n
    }).await.map_err(|_| err(500, "internal"))?;
    if n == 0 { Err(err(404, "not found")) } else { ok(json!({ "deleted": true })) }
}

// ---------- sync runs ----------

pub async fn trigger(State(reg): State<Arc<Registry>>, p: Principal, Path(source): Path<String>) -> R {
    p.require("sync:run", "manager")?;
    if source != "shopify" && source != "square" { return Err(err(404, "unknown source")); }
    master(&reg)?;
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let (d2, s2) = (db.clone(), source.clone());
    let connected = tokio::task::spawn_blocking(move || d2.with_reader(|c| c.query_row("SELECT count(*) FROM connections WHERE provider=?1", [&s2], |r| r.get::<_, i64>(0))).unwrap_or(0)).await.unwrap_or(0);
    if connected == 0 { return Err(err(409, "not connected")); }
    let slot = (p.tenant_id.clone(), source.clone());
    if !reg.sync_running.lock().insert(slot.clone()) { return Err(err(409, "a sync is already running")); }
    let (d3, s3) = (db.clone(), source.clone());
    let run_id = match tokio::task::spawn_blocking(move || {
        let c = d3.writer.lock();
        c.execute("INSERT INTO sync_runs(source,status,started_at) VALUES (?1,'running',?2)", params![s3, crate::now()]).map(|_| c.last_insert_rowid())
    }).await {
        Ok(Ok(id)) => id,
        _ => { reg.sync_running.lock().remove(&slot); return Err(err(500, "database error")); }
    };
    let r2 = reg.clone();
    let (tenant, src) = (p.tenant_id.clone(), source.clone());
    tokio::spawn(async move {
        // The semaphore bounds concurrent syncs process-wide, which bounds memory and upstream load.
        let _permit = r2.sync_sem.clone().acquire_owned().await;
        let (r3, t3, s3) = (r2.clone(), tenant.clone(), src.clone());
        let res = tokio::task::spawn_blocking(move || run(&r3, &t3, &s3, run_id)).await.unwrap_or_else(|_| Err("sync task panicked".into()));
        r2.sync_running.lock().remove(&(tenant, src));
        drop(res);
    });
    Ok((StatusCode::ACCEPTED, Json(json!({ "run_id": run_id, "source": source, "status": "running" }))).into_response())
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

fn publish(db: &TenantDb, evs: Vec<Ev>) { db.publish(evs); }

fn run(reg: &Registry, tenant: &str, source: &str, run_id: i64) -> Result<Value, String> {
    let db = reg.db(tenant).map_err(|e| e.to_string())?;
    let result = (|| {
        let key = reg.master.ok_or("RUPERT_MASTER_KEY is not configured")?;
        let blob: Vec<u8> = db.with_reader(|c| c.query_row("SELECT sealed FROM connections WHERE provider=?1", [source], |r| r.get(0))).map_err(|_| "not connected".to_string())?;
        let creds: Value = serde_json::from_slice(&crypto::open(&key, tenant, source, &blob).ok_or("stored credentials could not be decrypted")?).map_err(|_| "stored credentials are corrupt")?;
        let dev = |k: &str| if reg.auth.dev { std::env::var(k).ok() } else { None }; // test upstreams only in dev mode
        match source {
            "shopify" => {
                let base = dev("RUPERT_SHOPIFY_BASE").unwrap_or_else(|| format!("https://{}", creds["shop_domain"].as_str().unwrap_or_default()));
                sync_shopify(&db, run_id, Shopify::new(base, creds["client_id"].as_str().unwrap_or_default().into(), creds["client_secret"].as_str().unwrap_or_default().into()))
            }
            _ => {
                let base = dev("RUPERT_SQUARE_BASE").unwrap_or_else(|| if creds["environment"] == "sandbox" { "https://connect.squareupsandbox.com/v2".into() } else { "https://connect.squareup.com/v2".into() });
                sync_square(&db, run_id, Square::new(base, creds["access_token"].as_str().unwrap_or_default().into()))
            }
        }
    })();
    let (status, details, error) = match &result { Ok(d) => ("ok", Some(d.to_string()), None), Err(e) => ("failed", None, Some(e.chars().take(500).collect::<String>())) };
    let mut evs = Vec::new();
    {
        let mut c = db.writer.lock();
        if let Ok(tx) = c.transaction() {
            let _ = tx.execute("UPDATE sync_runs SET status=?2, finished_at=?3, details=?4, error=?5 WHERE id=?1", params![run_id, status, crate::now(), details, error]);
            if let Ok(Some(e)) = feed::emit_if(db.realtime(), &tx, "sync.finished", Some(source), &json!({ "run_id": run_id, "status": status, "error": error })) { evs.push(e); }
            feed::prune(&tx, 10_000);
            let _ = tx.commit();
        }
    }
    publish(&db, evs);
    result
}

// ---------- Shopify ingest ----------

fn sync_shopify(db: &TenantDb, run_id: i64, mut client: Shopify) -> Result<Value, String> {
    let (mut seen, mut added, mut changed, mut oversold) = (0i64, 0i64, 0i64, 0i64);
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
    let existing: i64 = db.with_reader(|c| c.query_row("SELECT count(*) FROM shopify_variants", [], |r| r.get(0))).unwrap_or(0);
    if seen == 0 && existing > 0 { return Err("Shopify returned no variants; refusing to remove the existing mirror".into()); }
    let removed = remove_stale(db, "shopify_variants", "shopify", run_id)?;
    Ok(json!({ "seen": seen, "added": added, "changed": changed, "removed": removed, "oversold": oversold }))
}

fn remove_stale(db: &TenantDb, table: &str, source: &str, run_id: i64) -> Result<i64, String> {
    let mut evs = Vec::new();
    let n;
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        let stale: Vec<(String, Option<String>)> = tx.prepare(&format!("SELECT id,sku FROM {table} WHERE synced_run<>?1")).and_then(|mut s| s.query_map([run_id], |r| Ok((r.get(0)?, r.get(1)?))).map(|i| i.flatten().collect())).map_err(|e| e.to_string())?;
        n = stale.len() as i64;
        for (id, sku) in &stale { evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.removed", Some(id), &json!({ "source": source, "sku": sku })).map_err(|e| e.to_string())?); }
        tx.execute(&format!("DELETE FROM {table} WHERE synced_run<>?1"), [run_id]).map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    Ok(n)
}

// ---------- Square ingest ----------

fn sync_square(db: &TenantDb, run_id: i64, client: Square) -> Result<Value, String> {
    let locations = client.locations()?;
    if locations.is_empty() { return Err("Square returned no active locations".into()); }
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
    let existing: i64 = db.with_reader(|c| c.query_row("SELECT count(*) FROM square_variations", [], |r| r.get(0))).unwrap_or(0);
    if seen == 0 && existing > 0 { return Err("Square returned no variations; refusing to remove the existing mirror".into()); }
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
            tx.execute("UPDATE square_variations SET qty=?2 WHERE id=?1", params![id, to]).map_err(|e| e.to_string())?;
            changed += 1;
            evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.changed", Some(&id), &json!({ "source": "square", "sku": sku, "qty": { "from": from, "to": to } })).map_err(|e| e.to_string())?);
        }
        tx.execute("DELETE FROM square_counts WHERE synced_run<>?1", [run_id]).map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    let removed = remove_stale(db, "square_variations", "square", run_id)?;
    Ok(json!({ "seen": seen, "added": added, "changed": changed, "removed": removed, "locations": locations.len() }))
}

// ---------- mirror reads (shape follows docs/api-v1.md) ----------

#[derive(Deserialize)]
pub struct ListQ { source: Option<String>, page: Option<i64>, per_page: Option<i64> }

fn page_params(q: &ListQ) -> Result<(String, i64, i64), Response> {
    let source = q.source.clone().unwrap_or_else(|| "shopify".into());
    if source != "shopify" && source != "square" { return Err(err(400, "source must be shopify or square")); }
    let (page, per) = (q.page.unwrap_or(1), q.per_page.unwrap_or(50));
    if !(1..=1000).contains(&page) || !(1..=100).contains(&per) { return Err(err(400, "page must be 1-1000 and per_page 1-100")); }
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
    ok(json!({ "data": rows, "meta": { "page": page, "per_page": per, "has_more": has_more, "next_page": has_more.then_some(page + 1) } }))
}

pub async fn catalog(State(reg): State<Arc<Registry>>, p: Principal, Query(q): Query<ListQ>) -> R { list(reg, p, "catalog:read", q, false).await }
pub async fn inventory(State(reg): State<Arc<Registry>>, p: Principal, Query(q): Query<ListQ>) -> R { list(reg, p, "inventory:read", q, true).await }
