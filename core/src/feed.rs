//! Realtime change feed. Every change appends a row to the tenant's `events`
//! outbox inside the same transaction as the change, then is broadcast after
//! commit. SSE clients replay from the outbox (Last-Event-ID / ?since=) and then
//! follow the broadcast, so a dropped connection or a lagging client loses nothing.
use crate::{
    auth::Principal,
    tenants::{Registry, TenantDb},
};
use axum::{
    Json,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{
        IntoResponse, Response, Sse,
        sse::{Event, KeepAlive},
    },
};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    convert::Infallible,
    sync::{Arc, atomic::Ordering},
    time::Duration,
};
use tokio::sync::{broadcast::error::RecvError, mpsc};
use tokio_stream::wrappers::ReceiverStream;

const REPLAY_BATCH: i64 = 500;
const MAX_STREAM_SECS: u64 = 600; // clients reconnect with Last-Event-ID; bounds how long a revoked token can keep a stream
const PER_TENANT_CLIENTS: usize = 50;

#[derive(Clone, Serialize)]
pub struct Ev {
    pub id: i64,
    pub at: i64,
    pub kind: String,
    pub key: Option<String>,
    pub data: Value,
}

pub fn emit(c: &Connection, kind: &str, key: Option<&str>, data: &Value) -> rusqlite::Result<Ev> {
    let at = crate::now();
    c.prepare_cached("INSERT INTO events(at,kind,key,data) VALUES (?1,?2,?3,?4)")?
        .execute((at, kind, key, data.to_string()))?;
    Ok(Ev {
        id: c.last_insert_rowid(),
        at,
        kind: kind.into(),
        key: key.map(String::from),
        data: data.clone(),
    })
}

/// `emit` unless the tenant has realtime switched off (then no row is written and `None` returned).
pub fn emit_if(
    on: bool,
    c: &Connection,
    kind: &str,
    key: Option<&str>,
    data: &Value,
) -> rusqlite::Result<Option<Ev>> {
    if on {
        emit(c, kind, key, data).map(Some)
    } else {
        Ok(None)
    }
}

pub fn prune(c: &Connection, keep: i64) {
    let _ = c.execute(
        "DELETE FROM events WHERE id <= (SELECT max(id) FROM events) - ?1",
        [keep],
    );
}

fn since(db: &TenantDb, after: i64, limit: i64) -> rusqlite::Result<Vec<Ev>> {
    db.with_reader(|c| {
        let mut s = c.prepare_cached(
            "SELECT id,at,kind,key,data FROM events WHERE id>?1 ORDER BY id LIMIT ?2",
        )?;
        let rows = s.query_map((after, limit), |r| {
            Ok(Ev {
                id: r.get(0)?,
                at: r.get(1)?,
                kind: r.get(2)?,
                key: r.get(3)?,
                data: serde_json::from_str(&r.get::<_, String>(4)?).unwrap_or(Value::Null),
            })
        })?;
        rows.collect()
    })
}

fn disabled() -> Response {
    (
        StatusCode::CONFLICT,
        Json(json!({ "error": "realtime is disabled for this tenant" })),
    )
        .into_response()
}

#[derive(Deserialize)]
pub struct SinceQ {
    since: Option<i64>,
    limit: Option<i64>,
}

pub async fn recent(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Query(q): Query<SinceQ>,
) -> Result<Json<Value>, Response> {
    p.require("inventory:read", "staff")?;
    let db = reg
        .db(&p.tenant_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
    if !db.realtime() {
        return Err(disabled());
    }
    let (after, limit) = (
        q.since.unwrap_or(0).max(0),
        q.limit.unwrap_or(100).clamp(1, 500),
    );
    let rows = tokio::task::spawn_blocking(move || since(&db, after, limit))
        .await
        .ok()
        .and_then(Result::ok)
        .ok_or_else(|| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
    Ok(Json(
        json!({ "data": rows, "meta": { "last_id": rows.last().map(|e| e.id) } }),
    ))
}

struct ClientGuard(Arc<TenantDb>, Arc<Registry>);
impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.0.sse_clients.fetch_sub(1, Ordering::Relaxed);
        self.1.sse_total.fetch_sub(1, Ordering::Relaxed);
    }
}

fn to_sse(e: &Ev) -> Event {
    Event::default()
        .id(e.id.to_string())
        .event(e.kind.clone())
        .data(
            json!({ "id": e.id, "at": e.at, "kind": e.kind, "key": e.key, "data": e.data })
                .to_string(),
        )
}

/// Sends events after `last` from the outbox; returns false if the client went away.
async fn replay(
    db: &Arc<TenantDb>,
    last: &mut i64,
    tx: &mpsc::Sender<Result<Event, Infallible>>,
) -> bool {
    loop {
        let (d, after) = (db.clone(), *last);
        let batch = match tokio::task::spawn_blocking(move || since(&d, after, REPLAY_BATCH)).await
        {
            Ok(Ok(b)) => b,
            _ => return true,
        };
        let n = batch.len() as i64;
        for e in batch {
            *last = e.id;
            if tx.send(Ok(to_sse(&e))).await.is_err() {
                return false;
            }
        }
        if n < REPLAY_BATCH {
            return true;
        }
    }
}

pub async fn stream(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    headers: HeaderMap,
    Query(q): Query<SinceQ>,
) -> Result<impl IntoResponse, Response> {
    p.require("inventory:read", "staff")?;
    let db = reg
        .db(&p.tenant_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
    if !db.realtime() {
        return Err(disabled());
    }
    if db.sse_clients.fetch_add(1, Ordering::Relaxed) >= PER_TENANT_CLIENTS
        || reg.sse_total.fetch_add(1, Ordering::Relaxed) >= reg.sse_max
    {
        db.sse_clients.fetch_sub(1, Ordering::Relaxed);
        reg.sse_total.fetch_sub(1, Ordering::Relaxed);
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({ "error": "too many streams" })),
        )
            .into_response());
    }
    let guard = ClientGuard(db.clone(), reg.clone());
    let mut rx = db.bus.subscribe(); // subscribe before replay so nothing falls in the gap
    let hdr = headers
        .get("last-event-id")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<i64>().ok());
    let mut last = match hdr.or(q.since) {
        Some(s) => s.max(0),
        None => db.last_event.load(Ordering::Acquire),
    };
    let (tx, out) = mpsc::channel(64);
    tokio::spawn(async move {
        let _g = guard;
        // Nothing to replay for a client that is already current: skip the DB read (and the
        // reader connection it would open).
        if db.last_event.load(Ordering::Acquire) > last && !replay(&db, &mut last, &tx).await {
            return;
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(MAX_STREAM_SECS);
        loop {
            tokio::select! {
                r = rx.recv() => match r {
                    Ok(e) => if e.id > last { last = e.id; if tx.send(Ok(to_sse(&e))).await.is_err() { return; } },
                    Err(RecvError::Lagged(_)) => if !replay(&db, &mut last, &tx).await { return; },
                    Err(RecvError::Closed) => return,
                },
                _ = tokio::time::sleep_until(deadline) => return,
                _ = tx.closed() => return,
            }
        }
    });
    Ok(Sse::new(ReceiverStream::new(out))
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
}

// ---------- per-tenant settings ----------

pub async fn get_settings(
    State(reg): State<Arc<Registry>>,
    p: Principal,
) -> Result<Json<Value>, Response> {
    p.require("inventory:read", "staff")?;
    let db = reg
        .db(&p.tenant_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
    Ok(Json(json!({ "realtime": db.realtime() })))
}

#[derive(Deserialize)]
pub struct SettingsBody {
    realtime: bool,
}

pub async fn put_settings(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Json(b): Json<SettingsBody>,
) -> Result<Json<Value>, Response> {
    if p.token_id.is_some() {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "settings are managed by signed-in owners" })),
        )
            .into_response());
    }
    p.require("settings:write", "owner")?;
    let db = reg
        .db(&p.tenant_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
    let (d2, r2, p2) = (db.clone(), reg.clone(), p.clone());
    tokio::task::spawn_blocking(move || {
        d2.set_realtime(b.realtime)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())?;
        crate::auth::audit(
            &r2.central.lock(),
            Some(&p2.tenant_id),
            Some(p2.user_id),
            "setting_realtime",
            if b.realtime { "on" } else { "off" },
        );
        Ok::<(), Response>(())
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())??;
    Ok(Json(json!({ "realtime": db.realtime() })))
}
