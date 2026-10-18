// axum handlers here conventionally return `Result<_, Response>`, whose error
// variant is large (a full HTTP response). Re-typing every handler around a boxed
// error would be invasive for no runtime benefit, so allow the lint crate-wide.
#![allow(clippy::result_large_err)]

mod auth;
mod crypto;
mod feed;
mod hooks;
mod migrate;
mod sync;
mod tenants;
mod upstream;

use auth::Principal;
use axum::{
    Json, Router,
    extract::{MatchedPath, Query, Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use serde::{Deserialize, Serialize};
use std::{net::SocketAddr, path::PathBuf, sync::Arc};
use tenants::Registry;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const GIT_REV: &str = match option_env!("RUPERT_GIT_REV") {
    Some(r) => r,
    None => "unknown",
};
static STARTED: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
pub fn uptime_secs() -> u64 {
    STARTED.get().map(|t| t.elapsed().as_secs()).unwrap_or(0)
}

/// One JSON object per line on stderr (journald picks it up). Never pass secrets or raw URLs here.
pub fn log(level: &str, msg: &str, extra: serde_json::Value) {
    let mut o = serde_json::json!({ "ts": now(), "level": level, "msg": msg });
    if let (Some(m), Some(e)) = (o.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            m.insert(k.clone(), v.clone());
        }
    }
    eprintln!("{o}");
}

/// Access log by route *template* (so `/hooks/{provider}/{token}` never exposes the token), no query strings,
/// no headers. Errors and slow requests are always logged; everything with RUPERT_ACCESS_LOG=1.
async fn access_log(req: Request, next: Next) -> Response {
    let (method, route) = (
        req.method().to_string(),
        req.extensions()
            .get::<MatchedPath>()
            .map(|m| m.as_str().to_string())
            .unwrap_or_else(|| "-".into()),
    );
    let t = std::time::Instant::now();
    let res = next.run(req).await;
    let (ms, status) = (t.elapsed().as_millis() as u64, res.status().as_u16());
    if status >= 500 || ms >= 1000 || std::env::var("RUPERT_ACCESS_LOG").as_deref() == Ok("1") {
        log(
            "info",
            "request",
            serde_json::json!({ "method": method, "route": route, "status": status, "ms": ms }),
        );
    }
    res
}

async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};
    let mut term = signal(SignalKind::terminate()).expect("SIGTERM handler");
    tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

type App = Arc<Registry>;

fn jerr(c: StatusCode, m: &str) -> Response {
    (c, Json(serde_json::json!({ "error": m }))).into_response()
}

fn tenant_db(app: &Registry, p: &Principal) -> Result<Arc<tenants::TenantDb>, Response> {
    app.db(&p.tenant_id).map_err(|_| {
        jerr(
            StatusCode::INTERNAL_SERVER_ERROR,
            "tenant database unavailable",
        )
    })
}

#[derive(Serialize)]
pub struct Item {
    pub sku: String,
    pub name: String,
    pub qty: i64,
}

#[derive(Deserialize)]
struct SkuQ {
    sku: String,
}

async fn get_item(
    State(app): State<App>,
    p: Principal,
    Query(q): Query<SkuQ>,
) -> Result<Json<Item>, Response> {
    p.require("inventory:read", "staff")?;
    let db = tenant_db(&app, &p)?;
    tokio::task::spawn_blocking(move || {
        db.with_reader(|c| {
            c.prepare_cached("SELECT sku,name,qty FROM inventory_items WHERE sku=?1")?
                .query_row([&q.sku], |r| {
                    Ok(Item {
                        sku: r.get(0)?,
                        name: r.get(1)?,
                        qty: r.get(2)?,
                    })
                })
        })
        .map(Json)
        .map_err(|_| jerr(StatusCode::NOT_FOUND, "not found"))
    })
    .await
    .map_err(|_| jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal"))?
}

#[derive(Deserialize)]
pub struct Adjust {
    pub sku: String,
    pub delta: i64,
    pub reason: String,
}

async fn adjust(
    State(app): State<App>,
    p: Principal,
    Json(a): Json<Adjust>,
) -> Result<Json<Item>, Response> {
    p.require("inventory:write", "manager")?;
    if a.reason.len() > 200 || a.sku.len() > 100 {
        return Err(jerr(StatusCode::BAD_REQUEST, "invalid input"));
    }
    let db = tenant_db(&app, &p)?;
    match db.submit(a).await {
        Ok(Ok(item)) => Ok(Json(item)),
        Ok(Err(404)) => Err(jerr(StatusCode::NOT_FOUND, "not found")),
        _ => Err(jerr(StatusCode::INTERNAL_SERVER_ERROR, "internal")),
    }
}

#[derive(Deserialize)]
struct NewItem {
    sku: String,
    name: String,
    qty: i64,
}

async fn put_item(
    State(app): State<App>,
    p: Principal,
    Json(i): Json<NewItem>,
) -> Result<Json<Item>, Response> {
    p.require("inventory:write", "manager")?;
    if i.sku.is_empty() || i.sku.len() > 100 || i.name.len() > 200 {
        return Err(jerr(StatusCode::BAD_REQUEST, "invalid input"));
    }
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
    format!(
        "rupert_{}",
        URL_SAFE_NO_PAD.encode(Sha256::digest(format!("rupert-dev-{t}")))
    )
}

#[derive(Deserialize)]
struct SeedQ {
    tenants: usize,
    items: usize,
}

/// Dev-only (RUPERT_DEV=1): N tenants with M items, one owner + full-scope token each.
async fn seed(State(app): State<App>, Query(q): Query<SeedQ>) -> Response {
    if !app.auth.dev {
        return jerr(StatusCode::NOT_FOUND, "not found");
    }
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

fn main() {
    // Bound the blocking pool: its default (512 threads) lets a burst of requests pin
    // hundreds of thread stacks and allocator arenas that are never returned.
    let blocking = std::env::var("RUPERT_BLOCKING_THREADS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64);
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .max_blocking_threads(blocking)
        .build()
        .expect("runtime")
        .block_on(run());
}

async fn run() {
    let dir = PathBuf::from(std::env::var("RUPERT_DATA").unwrap_or_else(|_| "./data".into()));
    let max_open: u64 = std::env::var("RUPERT_MAX_OPEN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64);
    let app: App = Arc::new(Registry::new(dir, max_open).expect("open central db"));
    if std::env::var("RUPERT_SCHEDULER").as_deref() != Ok("0") {
        tokio::spawn(sync::scheduler(app.clone()));
    }
    let r = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/v1/item", get(get_item).post(put_item))
        .route("/api/v1/adjust", post(adjust))
        .route("/dev/seed", post(seed))
        .route("/api/v1/events", get(feed::stream))
        .route("/api/v1/events/recent", get(feed::recent))
        .route(
            "/api/v1/settings",
            get(feed::get_settings).put(feed::put_settings),
        )
        .route("/api/v1/catalog", get(sync::catalog))
        .route("/api/v1/inventory", get(sync::inventory))
        .route("/api/v1/connections", get(sync::list_connections))
        .route(
            "/api/v1/connections/{provider}",
            put(sync::put_connection).delete(sync::delete_connection),
        )
        .route("/api/v1/sync/runs", get(sync::runs))
        .route("/api/v1/sync/usage", get(sync::usage))
        .route("/api/v1/webhooks", get(hooks::status))
        .route(
            "/api/v1/webhooks/token",
            post(hooks::rotate_token).delete(hooks::disable),
        )
        .route(
            "/hooks/{provider}/{token}",
            post(hooks::receive).layer(axum::extract::DefaultBodyLimit::max(1024 * 1024)),
        )
        .route("/api/v1/orders", get(sync::orders_list))
        .route("/api/v1/orders/detail", get(sync::order_detail))
        .route(
            "/api/v1/sync/schedule",
            get(sync::get_schedule).put(sync::put_schedule),
        )
        .route("/api/v1/locations", get(sync::locations))
        .route("/api/v1/inventory/levels", get(sync::levels))
        .route("/api/v1/sync/{source}", post(sync::trigger))
        .route("/api/v1/health", get(sync::health))
        .merge(auth::routes())
        .layer(axum::middleware::from_fn(access_log))
        .with_state(app.clone());
    let addr = std::env::var("RUPERT_LISTEN").unwrap_or_else(|_| "127.0.0.1:8799".into());
    let l = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    STARTED.get_or_init(std::time::Instant::now);
    log(
        "info",
        "listening",
        serde_json::json!({ "addr": addr, "version": VERSION, "git_rev": GIT_REV, "dev": app.auth.dev, "scheduler": std::env::var("RUPERT_SCHEDULER").as_deref() != Ok("0") }),
    );

    // Stop: close the listener, end SSE streams, let in-flight requests and running syncs finish (bounded),
    // then fold every WAL into its database so a snapshot or backup taken afterwards is complete.
    let a2 = app.clone();
    let server = axum::serve(l, r.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async move {
            shutdown_signal().await;
            log("info", "shutdown requested", serde_json::json!({}));
            let _ = a2.shutdown.send(true);
        });
    let mut down = app.shutdown.subscribe();
    let deadline = async {
        let _ = down.changed().await;
        tokio::time::sleep(std::time::Duration::from_secs(15)).await;
    };
    tokio::select! {
        r = server => { if let Err(e) = r { log("error", "server error", serde_json::json!({ "error": e.to_string() })); } }
        _ = deadline => log("warn", "connections still open after 15 s; stopping anyway", serde_json::json!({})),
    }
    for _ in 0..40 {
        if app.sync_running.lock().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    let running = app.sync_running.lock().len();
    let n = tokio::task::spawn_blocking({
        let a = app.clone();
        move || a.checkpoint_all()
    })
    .await
    .unwrap_or(0);
    log(
        "info",
        "stopped",
        serde_json::json!({ "checkpointed_databases": n, "syncs_interrupted": running }),
    );
}
