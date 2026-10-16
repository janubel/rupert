mod migrate;
mod tenants;

use axum::{Json, Router, extract::{Query, State}, http::{HeaderMap, StatusCode, header::HOST}, routing::{get, post}};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc};
use tenants::Registry;

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

type App = Arc<Registry>;
type Res<T> = Result<Json<T>, StatusCode>;

fn tenant_db(app: &Registry, h: &HeaderMap) -> Result<Arc<tenants::TenantDb>, StatusCode> {
    let host = h.get(HOST).and_then(|v| v.to_str().ok()).ok_or(StatusCode::BAD_REQUEST)?;
    let t = app.tenant_for_host(host).ok_or(StatusCode::NOT_FOUND)?;
    app.db(&t).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

#[derive(Serialize)]
pub struct Item { pub sku: String, pub name: String, pub qty: i64 }

#[derive(Deserialize)]
struct SkuQ { sku: String }

async fn get_item(State(app): State<App>, h: HeaderMap, Query(q): Query<SkuQ>) -> Res<Item> {
    let db = tenant_db(&app, &h)?;
    tokio::task::spawn_blocking(move || {
        db.with_reader(|c| c.prepare_cached("SELECT sku,name,qty FROM inventory_items WHERE sku=?1")?
            .query_row([&q.sku], |r| Ok(Item { sku: r.get(0)?, name: r.get(1)?, qty: r.get(2)? })))
            .map(Json).map_err(|_| StatusCode::NOT_FOUND)
    }).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
}

#[derive(Deserialize)]
pub struct Adjust { pub sku: String, pub delta: i64, pub reason: String }

async fn adjust(State(app): State<App>, h: HeaderMap, Json(a): Json<Adjust>) -> Res<Item> {
    let db = tenant_db(&app, &h)?;
    if tenants::cfg().group_commit {
        return match db.submit(a).await {
            Ok(Ok(item)) => Ok(Json(item)),
            Ok(Err(404)) => Err(StatusCode::NOT_FOUND),
            _ => Err(StatusCode::INTERNAL_SERVER_ERROR),
        };
    }
    tokio::task::spawn_blocking(move || {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let n = tx.prepare_cached("UPDATE inventory_items SET qty=qty+?2, updated_at=?3 WHERE sku=?1")
            .and_then(|mut s| s.execute((&a.sku, a.delta, now()))).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        if n == 0 { return Err(StatusCode::NOT_FOUND); }
        tx.prepare_cached("INSERT INTO movements(sku,delta,reason,at) VALUES (?1,?2,?3,?4)")
            .and_then(|mut s| s.execute((&a.sku, a.delta, &a.reason, now()))).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let item = tx.query_row("SELECT sku,name,qty FROM inventory_items WHERE sku=?1", [&a.sku],
            |r| Ok(Item { sku: r.get(0)?, name: r.get(1)?, qty: r.get(2)? })).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        tx.commit().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        Ok(Json(item))
    }).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
}

#[derive(Deserialize)]
struct SeedQ { tenants: usize, items: usize }

/// Dev-only: create N tenants (t0..tN) with M items each, hosts tK.local.
async fn seed(State(app): State<App>, Query(q): Query<SeedQ>) -> &'static str {
    tokio::task::spawn_blocking(move || {
        for t in 0..q.tenants {
            let id = format!("t{t}");
            app.create_tenant(&id, &id, &format!("{id}.local")).unwrap();
            let db = app.db(&id).unwrap();
            let mut c = db.writer.lock();
            let tx = c.transaction().unwrap();
            {
                let mut s = tx.prepare("INSERT OR IGNORE INTO inventory_items VALUES (?1,?2,1000000,?3)").unwrap();
                for i in 0..q.items { s.execute((format!("SKU-{i}"), format!("Item {i}"), now())).unwrap(); }
            }
            tx.commit().unwrap();
        }
    }).await.unwrap();
    "ok"
}

#[tokio::main]
async fn main() {
    let dir = PathBuf::from(std::env::var("RUPERT_DATA").unwrap_or_else(|_| "./data".into()));
    let max_open: u64 = std::env::var("RUPERT_MAX_OPEN").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
    let app: App = Arc::new(Registry::new(dir, max_open).expect("open central db"));
    let r = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/v1/item", get(get_item))
        .route("/api/v1/adjust", post(adjust))
        .route("/dev/seed", post(seed))
        .with_state(app);
    let addr = std::env::var("RUPERT_LISTEN").unwrap_or_else(|_| "127.0.0.1:8799".into());
    let l = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    axum::serve(l, r).await.unwrap();
}
