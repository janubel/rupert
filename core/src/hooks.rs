//! Shopify and Square webhooks: signed notifications that something changed.
//!
//! Receiving is deliberately dumb and safe:
//! - the URL carries a per-tenant secret token (stored only as a digest) and the body must carry a valid
//!   provider HMAC, checked in constant time with the secret we already hold;
//! - events are deduplicated by provider event id and acknowledged immediately;
//! - processing never trusts the payload for state. It re-reads the changed object from the provider
//!   (read-only calls, counted by the request meter and bounded by the hourly budget) and applies that.
//!
//! Registering a webhook subscription is a write to the provider, so this code never does it: the owner
//! adds the URL in the Shopify/Square dashboard (or explicitly approves a one-off registration).
use crate::{
    auth::{Principal, audit, client_key, err, limit, rand_token, sha_hex},
    feed,
    sync::{self, load_creds, make_shopify, make_square, publish, record_usage},
    tenants::{Registry, TenantDb},
    upstream::Meter,
};
use axum::{
    Json,
    body::Bytes,
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use hmac::{Hmac, Mac};
use rusqlite::params;
use serde_json::{Value, json};
use sha2::Sha256;
use std::{net::SocketAddr, sync::Arc};

type R = Result<Response, Response>;
type HmacSha256 = Hmac<Sha256>;

const TOKEN_LEN: usize = 4 + 43;
const DEBOUNCE_SECS: i64 = 60;

pub const SHOPIFY_TOPICS: &[&str] = &[
    "orders/create",
    "orders/updated",
    "orders/paid",
    "orders/cancelled",
    "orders/fulfilled",
    "inventory_levels/update",
    "products/create",
    "products/update",
    "products/delete",
    "inventory_items/update",
];
pub const SQUARE_TOPICS: &[&str] = &[
    "order.created",
    "order.updated",
    "inventory.count.updated",
    "catalog.version.updated",
];

fn public_url() -> String {
    std::env::var("RUPERT_PUBLIC_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:8798".into())
        .trim_end_matches('/')
        .to_string()
}

// ---------- owner endpoints ----------

/// Creates (or rotates) the tenant's webhook token. The full URLs are shown once; only a digest is kept.
pub async fn rotate_token(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    if p.token_id.is_some() {
        return Err(err(403, "webhooks are managed by signed-in owners"));
    }
    p.require("webhooks:write", "owner")?;
    let token = rand_token("rwh_");
    let (r2, p2, d) = (reg.clone(), p.clone(), sha_hex(&token));
    tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        let _ = c.execute(
            "DELETE FROM webhook_tokens WHERE tenant_id=?1",
            [&p2.tenant_id],
        );
        let _ = c.execute(
            "INSERT INTO webhook_tokens VALUES (?1,?2,?3)",
            params![d, p2.tenant_id, crate::now()],
        );
        audit(
            &c,
            Some(&p2.tenant_id),
            Some(p2.user_id),
            "webhook_token_rotate",
            "",
        );
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    let base = public_url();
    Ok((StatusCode::CREATED, Json(json!({
        "token": token,
        "urls": { "shopify": format!("{base}/hooks/shopify/{token}"), "square": format!("{base}/hooks/square/{token}") },
        "topics": { "shopify": SHOPIFY_TOPICS, "square": SQUARE_TOPICS },
        "note": "shown once. Add these URLs in the Shopify and Square dashboards yourself; Rupert never registers webhooks. For Square also store the subscription's signature key and the exact notification URL with PUT /api/v1/connections/square (webhook_signature_key, webhook_url)."
    }))).into_response())
}

pub async fn disable(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    if p.token_id.is_some() {
        return Err(err(403, "webhooks are managed by signed-in owners"));
    }
    p.require("webhooks:write", "owner")?;
    let (r2, p2) = (reg.clone(), p.clone());
    tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        let _ = c.execute(
            "DELETE FROM webhook_tokens WHERE tenant_id=?1",
            [&p2.tenant_id],
        );
        audit(
            &c,
            Some(&p2.tenant_id),
            Some(p2.user_id),
            "webhook_token_disable",
            "",
        );
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    Ok((StatusCode::OK, Json(json!({ "enabled": false }))).into_response())
}

pub async fn status(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    p.require("inventory:read", "staff")?;
    let (r2, t) = (reg.clone(), p.tenant_id.clone());
    let enabled = tokio::task::spawn_blocking(move || {
        r2.central
            .lock()
            .query_row(
                "SELECT count(*) FROM webhook_tokens WHERE tenant_id=?1",
                [&t],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0)
            > 0
    })
    .await
    .unwrap_or(false);
    let db = reg.db(&p.tenant_id).map_err(|_| err(500, "internal"))?;
    let recent: Vec<Value> = tokio::task::spawn_blocking(move || db.with_reader(|c| {
        let mut s = c.prepare_cached("SELECT provider,topic,coalesce(outcome,'pending'),count(*),max(received_at) FROM webhook_events WHERE received_at>?1 GROUP BY 1,2,3 ORDER BY 5 DESC LIMIT 100")?;
        let v = s.query_map([crate::now() - 86400], |r| Ok(json!({ "provider": r.get::<_, String>(0)?, "topic": r.get::<_, String>(1)?, "outcome": r.get::<_, String>(2)?, "count": r.get::<_, i64>(3)?, "last_received": r.get::<_, i64>(4)? })))?.flatten().collect();
        Ok(v)
    }).unwrap_or_default()).await.map_err(|_| err(500, "internal"))?;
    Ok((StatusCode::OK, Json(json!({ "enabled": enabled, "topics": { "shopify": SHOPIFY_TOPICS, "square": SQUARE_TOPICS }, "last_24h": recent }))).into_response())
}

// ---------- receiver (unauthenticated: the URL token and the provider HMAC are the authentication) ----------

fn header<'a>(h: &'a HeaderMap, k: &str) -> Option<&'a str> {
    h.get(k).and_then(|v| v.to_str().ok())
}

/// Constant-time HMAC check with the provider's own scheme.
fn signature_ok(provider: &str, creds: &Value, h: &HeaderMap, body: &[u8]) -> bool {
    let check = |key: &str, prefix: &str, sig: Option<&str>| -> bool {
        let Some(sig) = sig.and_then(|s| STANDARD.decode(s.trim()).ok()) else {
            return false;
        };
        if key.is_empty() {
            return false;
        }
        let Ok(mut mac) = HmacSha256::new_from_slice(key.as_bytes()) else {
            return false;
        };
        mac.update(prefix.as_bytes());
        mac.update(body);
        mac.verify_slice(&sig).is_ok()
    };
    if provider == "shopify" {
        check(
            creds["client_secret"].as_str().unwrap_or(""),
            "",
            header(h, "x-shopify-hmac-sha256"),
        )
    } else {
        // Square signs notification_url + body with the subscription's signature key.
        check(
            creds["webhook_signature_key"].as_str().unwrap_or(""),
            creds["webhook_url"].as_str().unwrap_or(""),
            header(h, "x-square-hmacsha256-signature"),
        )
    }
}

pub async fn receive(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    Path((provider, token)): Path<(String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let nf = || err(404, "not found");
    if (provider != "shopify" && provider != "square")
        || token.len() != TOKEN_LEN
        || !token.starts_with("rwh_")
    {
        return nf();
    }
    let digest = sha_hex(&token);
    if let Err(r) = limit(&reg, format!("hook|{digest}"), 600) {
        return r;
    }
    if let Err(r) = limit(
        &reg,
        format!("hookip|{}", client_key(&reg, ci, &headers)),
        1200,
    ) {
        return r;
    }

    // token -> tenant -> credentials. Unknown token, no connection or bad signature are indistinguishable
    // from the outside except for the signature failure (401), which needs a valid token to reach.
    let (r2, d2) = (reg.clone(), digest.clone());
    let Some(tenant) = tokio::task::spawn_blocking(move || {
        r2.central
            .lock()
            .query_row(
                "SELECT tenant_id FROM webhook_tokens WHERE digest=?1",
                [&d2],
                |r| r.get::<_, String>(0),
            )
            .ok()
    })
    .await
    .ok()
    .flatten() else {
        return nf();
    };
    let Ok(db) = reg.db(&tenant) else {
        return err(500, "internal");
    };
    let (r3, db3, t3, p3) = (reg.clone(), db.clone(), tenant.clone(), provider.clone());
    let Some(creds) = tokio::task::spawn_blocking(move || load_creds(&r3, &db3, &t3, &p3).ok())
        .await
        .ok()
        .flatten()
    else {
        return nf();
    };
    if !signature_ok(&provider, &creds, &headers, &body) {
        return err(401, "invalid signature");
    }

    let payload: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (event_id, topic) = if provider == "shopify" {
        (
            header(&headers, "x-shopify-event-id")
                .or(header(&headers, "x-shopify-webhook-id"))
                .unwrap_or("")
                .to_string(),
            header(&headers, "x-shopify-topic")
                .unwrap_or("")
                .to_string(),
        )
    } else {
        (
            payload["event_id"].as_str().unwrap_or("").to_string(),
            payload["type"].as_str().unwrap_or("").to_string(),
        )
    };
    if event_id.is_empty() || event_id.len() > 200 || topic.is_empty() || topic.len() > 100 {
        return err(400, "missing event id or topic");
    }

    // Dedupe: providers retry, and may deliver the same event more than once.
    let (key, pr, tp, d4) = (
        format!("{provider}:{event_id}"),
        provider.clone(),
        topic.clone(),
        db.clone(),
    );
    let fresh = tokio::task::spawn_blocking(move || {
        let c = d4.writer.lock();
        let _ = c.execute("DELETE FROM webhook_events WHERE received_at<?1", [crate::now() - 7 * 86400]);
        c.execute("INSERT OR IGNORE INTO webhook_events(id,provider,topic,received_at) VALUES (?1,?2,?3,?4)", params![key, pr, tp, crate::now()]).unwrap_or(0) == 1
    }).await.unwrap_or(false);
    if !fresh {
        return (StatusCode::OK, Json(json!({ "status": "duplicate" }))).into_response();
    }

    let (r5, key) = (reg.clone(), format!("{provider}:{event_id}"));
    tokio::spawn(async move {
        let _permit = r5.hook_sem.clone().acquire_owned().await; // bounds concurrent refreshes
        let (r6, t6, p6, tp6, pl6) = (
            r5.clone(),
            tenant.clone(),
            provider.clone(),
            topic.clone(),
            payload,
        );
        let outcome = tokio::task::spawn_blocking(move || process(&r6, &t6, &p6, &tp6, &pl6))
            .await
            .unwrap_or(Outcome::Failed("panic".into()));
        let label = match outcome {
            Outcome::NeedSync => {
                // Catalog-level change: one debounced full read-only sync instead of one per event.
                let now = crate::now();
                let go = {
                    let mut m = r5.hook_debounce.lock();
                    let last = m
                        .get(&(tenant.clone(), provider.clone()))
                        .copied()
                        .unwrap_or(0);
                    if now - last >= DEBOUNCE_SECS {
                        m.insert((tenant.clone(), provider.clone()), now);
                        true
                    } else {
                        false
                    }
                };
                if !go {
                    "debounced".to_string()
                } else {
                    match sync::start_sync(&r5, &tenant, &provider).await {
                        Ok(_) => "sync_started".into(),
                        Err((_, m)) => format!("sync_not_started: {m}"),
                    }
                }
            }
            Outcome::Done(s) => s.to_string(),
            Outcome::Skipped(s) => format!("skipped: {s}"),
            Outcome::Failed(e) => format!("failed: {}", e.chars().take(120).collect::<String>()),
        };
        if let Ok(db) = r5.db(&tenant) {
            let _ = tokio::task::spawn_blocking(move || {
                db.writer.lock().execute(
                    "UPDATE webhook_events SET outcome=?2 WHERE id=?1",
                    params![key, label],
                )
            })
            .await;
        }
    });
    (StatusCode::OK, Json(json!({ "status": "accepted" }))).into_response()
}

// ---------- processing ----------

enum Outcome {
    Done(&'static str),
    Skipped(&'static str),
    NeedSync,
    Failed(String),
}

fn process(reg: &Registry, tenant: &str, provider: &str, topic: &str, payload: &Value) -> Outcome {
    let Ok(db) = reg.db(tenant) else {
        return Outcome::Failed("tenant database unavailable".into());
    };
    let used: i64 = db
        .with_reader(|c| {
            c.query_row(
                "SELECT coalesce(sum(requests),0) FROM api_usage WHERE provider=?1 AND bucket>?2",
                params![provider, crate::now() / sync::BUCKET_SECS - 6],
                |r| r.get(0),
            )
        })
        .unwrap_or(0);
    if used >= sync::hourly_budget() {
        return Outcome::Skipped("hourly API budget used up; the scheduled sync will catch up");
    }
    let creds = match load_creds(reg, &db, tenant, provider) {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(e),
    };
    let meter = Meter::shared(sync::run_cap());
    let out = if provider == "shopify" {
        shopify_event(reg, &db, &creds, &meter, topic, payload)
    } else {
        square_event(reg, &db, &creds, &meter, topic, payload)
    };
    record_usage(&db, provider, &meter);
    out.unwrap_or_else(Outcome::Failed)
}

fn shopify_event(
    reg: &Registry,
    db: &TenantDb,
    creds: &Value,
    meter: &crate::upstream::SharedMeter,
    topic: &str,
    payload: &Value,
) -> Result<Outcome, String> {
    if topic == "orders/delete" {
        return Ok(Outcome::Skipped("order deletions are not mirrored"));
    }
    if topic.starts_with("orders/") {
        let gid = payload["admin_graphql_api_id"]
            .as_str()
            .map(String::from)
            .or_else(|| {
                payload["id"]
                    .as_i64()
                    .map(|n| format!("gid://shopify/Order/{n}"))
            })
            .ok_or("no order id in payload")?;
        let mut client = make_shopify(reg, creds, meter.clone());
        return Ok(match client.order(&gid)? {
            Some(o) => {
                sync::ingest_orders(db, "shopify", 0, &[o], false)?;
                Outcome::Done("order refreshed")
            }
            None => Outcome::Skipped("order not visible to this app"),
        });
    }
    if topic == "inventory_levels/update" {
        let item = payload["inventory_item_id"]
            .as_i64()
            .map(|n| format!("gid://shopify/InventoryItem/{n}"))
            .ok_or("no inventory_item_id in payload")?;
        let mut client = make_shopify(reg, creds, meter.clone());
        let known: i64 = db
            .with_reader(|c| {
                c.query_row(
                    "SELECT count(*) FROM shopify_variants WHERE inventory_item_id=?1",
                    [&item],
                    |r| r.get(0),
                )
            })
            .unwrap_or(0);
        if known == 0 {
            return Ok(Outcome::NeedSync);
        } // a variant we have not mirrored yet
        let levels = client
            .levels(std::slice::from_ref(&item))?
            .remove(&item)
            .unwrap_or_default();
        let total = client.item_total(&item)?;
        apply_shopify_item(db, &item, &levels, total)?;
        return Ok(Outcome::Done("inventory refreshed"));
    }
    if topic.starts_with("products/") || topic.starts_with("inventory_items/") {
        return Ok(Outcome::NeedSync);
    }
    Ok(Outcome::Skipped("topic not handled"))
}

/// Applies one item's freshly read levels and total with the same rules as a full sync.
fn apply_shopify_item(
    db: &TenantDb,
    item: &str,
    levels: &[(String, i64)],
    total: Option<i64>,
) -> Result<(), String> {
    let mut evs = Vec::new();
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        let known: std::collections::HashSet<String> = tx
            .prepare("SELECT id FROM shopify_locations")
            .and_then(|mut s| s.query_map([], |r| r.get(0)).map(|i| i.flatten().collect()))
            .map_err(|e| e.to_string())?;
        let primary: Option<String> = tx
            .query_row(
                "SELECT id FROM shopify_locations WHERE is_primary=1",
                [],
                |r| r.get(0),
            )
            .ok();
        let variants: Vec<(String, Option<String>, i64)> = tx
            .prepare("SELECT id,sku,qty FROM shopify_variants WHERE inventory_item_id=?1")
            .and_then(|mut s| {
                s.query_map([item], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                    .map(|i| i.flatten().collect())
            })
            .map_err(|e| e.to_string())?;
        for (vid, sku, old_total) in variants {
            let new_total = total.map(|t| t.max(0)).unwrap_or(old_total);
            if new_total != old_total {
                tx.execute(
                    "UPDATE shopify_variants SET qty=?2 WHERE id=?1",
                    params![vid, new_total],
                )
                .map_err(|e| e.to_string())?;
                evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.changed", Some(&vid), &json!({ "source": "shopify", "sku": sku, "qty": { "from": old_total, "to": new_total }, "via": "webhook" })).map_err(|e| e.to_string())?);
            }
            let rows: Vec<(String, i64, i64)> = if levels.is_empty() {
                primary
                    .iter()
                    .map(|p| (p.clone(), new_total, total.unwrap_or(old_total)))
                    .collect()
            } else {
                levels
                    .iter()
                    .filter(|(l, _)| known.contains(l))
                    .map(|(l, a)| (l.clone(), (*a).max(0), *a))
                    .collect()
            };
            for (loc, qty, raw) in rows {
                let old: Option<i64> = tx
                    .query_row(
                        "SELECT qty FROM shopify_levels WHERE variant_id=?1 AND location_id=?2",
                        params![vid, loc],
                        |r| r.get(0),
                    )
                    .ok();
                tx.execute("INSERT INTO shopify_levels(variant_id,location_id,qty,raw_qty,synced_run) VALUES (?1,?2,?3,?4,0) ON CONFLICT(variant_id,location_id) DO UPDATE SET qty=excluded.qty,raw_qty=excluded.raw_qty",
                    params![vid, loc, qty, raw]).map_err(|e| e.to_string())?;
                if let Some(o) = old.filter(|o| *o != qty) {
                    evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.level.changed", Some(&vid), &json!({ "source": "shopify", "sku": sku, "location_id": loc, "qty": { "from": o, "to": qty }, "via": "webhook" })).map_err(|e| e.to_string())?);
                }
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    Ok(())
}

fn square_event(
    reg: &Registry,
    db: &TenantDb,
    creds: &Value,
    meter: &crate::upstream::SharedMeter,
    topic: &str,
    payload: &Value,
) -> Result<Outcome, String> {
    let obj = &payload["data"]["object"];
    match topic {
        "order.created" | "order.updated" => {
            let o = if topic == "order.created" {
                &obj["order_created"]
            } else {
                &obj["order_updated"]
            };
            let (id, loc) = (
                o["order_id"].as_str().ok_or("no order_id in payload")?,
                o["location_id"]
                    .as_str()
                    .ok_or("no location_id in payload")?,
            );
            let client = make_square(reg, creds, meter.clone());
            let orders: Vec<_> = client
                .orders_by_ids(loc, &[id.to_string()])?
                .into_iter()
                .filter(|o| matches!(o.status.as_deref(), Some("COMPLETED") | Some("CANCELED")))
                .collect();
            if orders.is_empty() {
                return Ok(Outcome::Skipped("order not completed yet"));
            }
            sync::ingest_orders(db, "square", 0, &orders, false)?;
            Ok(Outcome::Done("order refreshed"))
        }
        "inventory.count.updated" => {
            let ids: Vec<String> = obj["inventory_counts"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|c| c["catalog_object_id"].as_str().map(String::from))
                .collect::<std::collections::HashSet<_>>()
                .into_iter()
                .collect();
            if ids.is_empty() {
                return Ok(Outcome::Skipped("no catalog objects in payload"));
            }
            let locs: Vec<String> = db
                .with_reader(|c| {
                    let mut s = c.prepare("SELECT id FROM square_locations")?;
                    let v = s.query_map([], |r| r.get(0))?.flatten().collect();
                    Ok(v)
                })
                .unwrap_or_default();
            if locs.is_empty() {
                return Ok(Outcome::NeedSync);
            }
            let known: i64 = db
                .with_reader(|c| {
                    c.query_row(
                        &format!(
                            "SELECT count(*) FROM square_variations WHERE id IN ({})",
                            vec!["?"; ids.len()].join(",")
                        ),
                        rusqlite::params_from_iter(ids.iter()),
                        |r| r.get(0),
                    )
                })
                .unwrap_or(0);
            if known == 0 {
                return Ok(Outcome::NeedSync);
            }
            let counts = make_square(reg, creds, meter.clone()).counts(&locs, &ids)?;
            apply_square_counts(db, &ids, &locs, &counts)?;
            Ok(Outcome::Done("inventory refreshed"))
        }
        "catalog.version.updated" => Ok(Outcome::NeedSync),
        _ => Ok(Outcome::Skipped("topic not handled")),
    }
}

/// `counts` only lists locations that have stock, so a requested (variation, location) pair that is absent is 0.
fn apply_square_counts(
    db: &TenantDb,
    ids: &[String],
    locs: &[String],
    counts: &[(String, String, i64)],
) -> Result<(), String> {
    let mut evs = Vec::new();
    {
        let mut c = db.writer.lock();
        let tx = c.transaction().map_err(|e| e.to_string())?;
        for id in ids {
            let sku: Option<String> = tx
                .query_row("SELECT sku FROM square_variations WHERE id=?1", [id], |r| {
                    r.get(0)
                })
                .ok()
                .flatten();
            let old_total: Option<i64> = tx
                .query_row("SELECT qty FROM square_variations WHERE id=?1", [id], |r| {
                    r.get(0)
                })
                .ok();
            let mut total = 0i64;
            for loc in locs {
                let q = counts
                    .iter()
                    .find(|(v, l, _)| v == id && l == loc)
                    .map(|(_, _, q)| *q);
                let old: Option<i64> = tx
                    .query_row(
                        "SELECT qty FROM square_counts WHERE variation_id=?1 AND location_id=?2",
                        params![id, loc],
                        |r| r.get(0),
                    )
                    .ok();
                match q {
                    Some(q) => {
                        total += q;
                        tx.execute("INSERT INTO square_counts VALUES (?1,?2,?3,0) ON CONFLICT(variation_id,location_id) DO UPDATE SET qty=excluded.qty", params![id, loc, q]).map_err(|e| e.to_string())?;
                    }
                    None => {
                        tx.execute(
                            "DELETE FROM square_counts WHERE variation_id=?1 AND location_id=?2",
                            params![id, loc],
                        )
                        .map_err(|e| e.to_string())?;
                    }
                }
                let new = q.unwrap_or(0);
                if let Some(o) = old.filter(|o| *o != new) {
                    evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.level.changed", Some(id), &json!({ "source": "square", "sku": sku, "location_id": loc, "qty": { "from": o, "to": new }, "via": "webhook" })).map_err(|e| e.to_string())?);
                }
            }
            if let Some(o) = old_total.filter(|o| *o != total) {
                tx.execute(
                    "UPDATE square_variations SET qty=?2 WHERE id=?1",
                    params![id, total],
                )
                .map_err(|e| e.to_string())?;
                evs.extend(feed::emit_if(db.realtime(), &tx, "mirror.variant.changed", Some(id), &json!({ "source": "square", "sku": sku, "qty": { "from": o, "to": total }, "via": "webhook" })).map_err(|e| e.to_string())?);
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    publish(db, evs);
    Ok(())
}
