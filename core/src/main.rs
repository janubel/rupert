mod auth;
mod crypto;
mod feed;
mod migrate;
mod sync;
mod tenants;
mod upstream;

use auth::Principal;
use axum::{Json, Router, extract::{Query, State}, http::StatusCode, response::{IntoResponse, Response}, routing::{get, post, put}};
use serde::{Deserialize, Serialize};
use std::{net::SocketAddr, path::PathBuf, sync::Arc};
use tenants::Registry;

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

type App = Arc<Registry>;

fn jerr(c: StatusCode, m: &str) -> Response { (c, Json(serde_json::json!({ "error": m }))).into_response() }

fn tenant_db(app: &Registry, p: &Principal) -> Result<Arc<tenants::TenantDb>, Response> {
    app.db(&p.tenant_id).map_err(|_| jerr(StatusCode::INTERNAL_SERVER_ERROR, "tenant database unavailable"))
}

#[derive(Serialize)]
pub struct Item { pub sku: String, pub name: String, pub qty: i64 }

#[derive(Deserialize)]
struct SkuQ { sku: String }

async fn get_item(State(app): State<App>, p: Principal, Query(q): Query<SkuQ>) -> Result<Json<Item>, Response> {
    p.require("inventory:read", "staff")?;
    let db = tenant_db(&app, &p)?;
    tokio::task::spawn_blocking(move || {
        db.with_reader(|c| c.prepare_cached("SELECT sku,name,qty FROM inventory_items WHERE sku=?1")?
            .query_row([&q.sku], |r| Ok(Item { sku: r.get(0)?, name: r.get(1)?, qty: r.get(2)? })))
            .map(Json).map_err(|_| jerr(StatusCode::NOT_FOUND, "not found"))
    }).await.map_err(|_| jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal"))?
}

#[derive(Deserialize)]
pub struct Adjust { pub sku: String, pub delta: i64, pub reason: String }

async fn adjust(State(app): State<App>, p: Principal, Json(a): Json<Adjust>) -> Result<Json<Item>, Response> {
    p.require("inventory:write", "manager")?;
    if a.reason.len() > 200 || a.sku.len() > 100 { return Err(jerr(StatusCode::BAD_REQUEST, "invalid input")); }
    let db = tenant_db(&app, &p)?;
    match db.submit(a).await {
        Ok(Ok(item)) => Ok(Json(item)),
        Ok(Err(404)) => Err(jerr(StatusCode::NOT_FOUND, "not found")),
        _ => Err(jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal")),
    }
}

#[derive(Deserialize)]
struct NewItem { sku: String, name: String, qty: i64 }

async fn put_item(State(app): State<App>, p: Principal, Json(i): Json<NewItem>) -> Result<Json<Item>, Response> {
    p.require("inventory:write", "manager")?;
    if i.sku.is_empty() || i.sku.len() > 100 || i.name.len() > 200 { return Err(jerr(StatusCode::BAD_REQUEST, "invalid input")); }
    let db = tenant_db(&app, &p)?;
    tokio::task::spawn_blocking(move || {
        db.writer.lock().execute("INSERT INTO inventory_items VALUES (?1,?2,?3,?4) ON CONFLICT(sku) DO UPDATE SET name=excluded.name, qty=excluded.qty, updated_at=excluded.updated_at",
            (&i.sku, &i.name, i.qty, now())).map(|_| Json(Item { sku: i.sku, name: i.name, qty: i.qty }))
            .map_err(|_| jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal"))
    }).await.map_err(|_| jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal"))?
}

/// Deterministic dev token for seeded tenant `t`, usable only when RUPERT_DEV=1.
pub fn dev_token(t: usize) -> String {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    use sha2::{Digest, Sha256};
    format!("rupert_{}", URL_SAFE_NO_PAD.encode(Sha256::digest(format!("rupert-dev-{t}"))))
}

#[derive(Deserialize)]
struct SeedQ { tenants: usize, items: usize }

/// Dev-only (RUPERT_DEV=1): N tenants with M items, one owner + full-scope token each.
async fn seed(State(app): State<App>, Query(q): Query<SeedQ>) -> Response {
    if !app.auth.dev { return jerr(StatusCode::NOT_FOUND, "not found"); }
    tokio::task::spawn_blocking(move || {
        for t in 0..q.tenants {
            let id = format!("t{t}");
            app.create_tenant(&id, &id, &format!("{id}.local")).unwrap();
            {
                let c = app.central.lock();
                c.execute("INSERT OR IGNORE INTO users(id,email,pw_hash,name,active,created_at) VALUES (?1,?2,'!',?3,1,0)", (t as i64 + 1, format!("dev{t}@example.test"), &id)).unwrap();
                c.execute("INSERT OR IGNORE INTO memberships VALUES (?1,?2,'owner')", (t as i64 + 1, &id)).unwrap();
                let tok = dev_token(t);
                c.execute("INSERT OR IGNORE INTO api_tokens VALUES (?1,?2,?3,'dev',?4,'dev','[\"inventory:read\",\"inventory:write\"]',NULL,NULL,0)",
                    (format!("tok_dev{t}"), &id, t as i64 + 1, auth::sha_hex(&tok))).unwrap();
            }
            let db = app.db(&id).unwrap();
            let mut c = db.writer.lock();
            let tx = c.transaction().unwrap();
            {
                let mut s = tx.prepare("INSERT OR IGNORE INTO inventory_items VALUES (?1,?2,1000000,?3)").unwrap();
                for i in 0..q.items { s.execute((format!("SKU-{i}"), format!("Item {i}"), now())).unwrap(); }
            }
            tx.commit().unwrap();
        }
        "ok".into_response()
    }).await.unwrap()
}

#[tokio::main]
async fn main() {
    let dir = PathBuf::from(std::env::var("RUPERT_DATA").unwrap_or_else(|_| "./data".into()));
    let max_open: u64 = std::env::var("RUPERT_MAX_OPEN").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
    let app: App = Arc::new(Registry::new(dir, max_open).expect("open central db"));
    let r = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/v1/item", get(get_item).post(put_item))
        .route("/api/v1/adjust", post(adjust))
        .route("/dev/seed", post(seed))
        .route("/api/v1/events", get(feed::stream))
        .route("/api/v1/events/recent", get(feed::recent))
        .route("/api/v1/catalog", get(sync::catalog))
        .route("/api/v1/inventory", get(sync::inventory))
        .route("/api/v1/connections", get(sync::list_connections))
        .route("/api/v1/connections/{provider}", put(sync::put_connection).delete(sync::delete_connection))
        .route("/api/v1/sync/runs", get(sync::runs))
        .route("/api/v1/sync/{source}", post(sync::trigger))
        .merge(auth::routes())
        .with_state(app);
    let addr = std::env::var("RUPERT_LISTEN").unwrap_or_else(|_| "127.0.0.1:8799".into());
    let l = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    axum::serve(l, r.into_make_service_with_connect_info::<SocketAddr>()).await.unwrap();
}
