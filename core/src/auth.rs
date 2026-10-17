//! Milestone 2: signup, login, sessions, memberships, invites, API tokens.
//!
//! Token formats match the Rails app: `rupert_` + 43 base64url chars, stored as a
//! SHA-256 hex digest. Secrets are returned exactly once and never stored.
//! Sessions use `rsess_`, invites `rinv_`. API tokens carry their own tenant;
//! hostnames can never change it. Sessions pick the tenant from the Host header
//! and must hold a membership there.
use crate::tenants::Registry;
use argon2::{
    Algorithm, Argon2, Params, PasswordHash, PasswordHasher, PasswordVerifier, Version,
    password_hash::SaltString,
};
use axum::{
    Json, Router,
    extract::{ConnectInfo, FromRequestParts, Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header, request::Parts},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use moka::sync::Cache;
use rusqlite::{Connection, params};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU32, Ordering},
    },
    time::Duration,
};
use tokio::sync::Semaphore;

pub const SCOPES: &[&str] = &[
    "catalog:read",
    "inventory:read",
    "inventory:write",
    "roadmap:read",
    "sync:run",
    "orders:read",
];
const SESSION_SECS: i64 = 14 * 86400;
const COOKIE: &str = "rupert_session";

pub struct AuthState {
    principals: Cache<String, Option<Principal>>,
    limiter: Cache<String, Arc<AtomicU32>>,
    hash_sem: Semaphore,
    dummy_hash: String,
    pub base_domain: String,
    trust_proxy: bool,
    secure_cookie: bool,
    pub dev: bool,
    /// Public signup is closed unless dev mode, `RUPERT_SIGNUP=open`, or the caller knows `RUPERT_SIGNUP_CODE`.
    signup_open: bool,
    signup_code: Option<String>,
}

impl AuthState {
    pub fn new() -> Self {
        let env = |k: &str| std::env::var(k).ok();
        Self {
            principals: Cache::builder()
                .max_capacity(50_000)
                .time_to_live(Duration::from_secs(5))
                .build(),
            limiter: Cache::builder()
                .max_capacity(100_000)
                .time_to_live(Duration::from_secs(60))
                .build(),
            // Argon2 is memory-hard: cap concurrent hashes so a login burst cannot balloon RSS.
            hash_sem: Semaphore::new(
                env("RUPERT_HASH_CONCURRENCY")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(2),
            ),
            dummy_hash: hash_pw("dummy-password-for-timing"),
            base_domain: env("RUPERT_BASE_DOMAIN").unwrap_or_else(|| "rupert.local".into()),
            trust_proxy: env("RUPERT_TRUST_PROXY").as_deref() == Some("1"),
            secure_cookie: env("RUPERT_COOKIE_SECURE").as_deref() != Some("0"),
            dev: env("RUPERT_DEV").as_deref() == Some("1"),
            signup_open: env("RUPERT_SIGNUP").as_deref() == Some("open")
                || env("RUPERT_DEV").as_deref() == Some("1"),
            signup_code: env("RUPERT_SIGNUP_CODE")
                .filter(|c| !c.is_empty())
                .map(|c| sha_hex(&c)),
        }
    }
}

// ---------- primitives ----------

fn argon() -> Argon2<'static> {
    // OWASP minimum for Argon2id: 19 MiB, 2 iterations, 1 lane.
    Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(19456, 2, 1, None).unwrap(),
    )
}
pub fn hash_pw(pw: &str) -> String {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).expect("os randomness");
    let salt = SaltString::encode_b64(&salt).unwrap();
    argon()
        .hash_password(pw.as_bytes(), &salt)
        .unwrap()
        .to_string()
}
fn verify_pw(pw: &str, hash: &str) -> bool {
    PasswordHash::new(hash)
        .map(|h| argon().verify_password(pw.as_bytes(), &h).is_ok())
        .unwrap_or(false)
}
/// Constant-time equality for equal-length secrets (digests).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn sha_hex(s: &str) -> String {
    Sha256::digest(s.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
pub(crate) fn rand_token(prefix: &str) -> String {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("os randomness");
    format!("{prefix}{}", URL_SAFE_NO_PAD.encode(b))
}
fn rand_id(prefix: &str) -> String {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("os randomness");
    format!(
        "{prefix}{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    )
}
fn rank(role: &str) -> u8 {
    match role {
        "owner" => 3,
        "manager" => 2,
        "staff" => 1,
        _ => 0,
    }
}

// ---------- responses ----------

type R = Result<Response, Response>;
pub(crate) fn err(code: u16, msg: &str) -> Response {
    (
        StatusCode::from_u16(code).unwrap(),
        Json(json!({ "error": msg })),
    )
        .into_response()
}
fn unauth() -> Response {
    let mut r = err(401, "authentication required");
    r.headers_mut()
        .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    r
}
fn dberr(e: rusqlite::Error) -> Response {
    if e.to_string().contains("UNIQUE") {
        err(409, "already exists")
    } else {
        err(500, "database error")
    }
}
fn ok(v: Value) -> R {
    Ok((StatusCode::OK, Json(v)).into_response())
}
fn created(v: Value) -> R {
    Ok((StatusCode::CREATED, Json(v)).into_response())
}
fn with_cookie(mut r: Response, a: &AuthState, secret: &str) -> Response {
    let c = format!(
        "{COOKIE}={secret}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_SECS}{}",
        if a.secure_cookie { "; Secure" } else { "" }
    );
    r.headers_mut()
        .insert(header::SET_COOKIE, HeaderValue::from_str(&c).unwrap());
    r
}

pub async fn no_store(req: axum::extract::Request, next: axum::middleware::Next) -> Response {
    let mut r = next.run(req).await;
    r.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    r
}

pub(crate) fn client_key(reg: &Registry, ci: SocketAddr, h: &HeaderMap) -> String {
    if reg.auth.trust_proxy {
        // The rightmost entry is the one our own proxy appended; earlier ones are client-controlled.
        if let Some(ip) = h
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
        {
            return ip.trim().to_string();
        }
    }
    ci.ip().to_string()
}
pub(crate) fn limit(reg: &Registry, key: String, max: u32) -> Result<(), Response> {
    let c = reg
        .auth
        .limiter
        .get_with(key, || Arc::new(AtomicU32::new(0)));
    if c.fetch_add(1, Ordering::Relaxed) >= max {
        Err(err(429, "too many requests"))
    } else {
        Ok(())
    }
}

async fn hash_async(reg: &Arc<Registry>, pw: String) -> Result<String, Response> {
    let _p = reg
        .auth
        .hash_sem
        .acquire()
        .await
        .map_err(|_| err(500, "busy"))?;
    tokio::task::spawn_blocking(move || hash_pw(&pw))
        .await
        .map_err(|_| err(500, "hash failed"))
}
async fn verify_async(reg: &Arc<Registry>, pw: String, hash: String) -> bool {
    let Ok(_p) = reg.auth.hash_sem.acquire().await else {
        return false;
    };
    tokio::task::spawn_blocking(move || verify_pw(&pw, &hash))
        .await
        .unwrap_or(false)
}

pub(crate) fn audit(
    c: &Connection,
    tenant: Option<&str>,
    user: Option<i64>,
    action: &str,
    detail: &str,
) {
    let _ = c.execute(
        "INSERT INTO audit(at,tenant_id,user_id,action,detail) VALUES (?1,?2,?3,?4,?5)",
        params![crate::now(), tenant, user, action, detail],
    );
}

fn new_session(c: &Connection, user_id: i64) -> rusqlite::Result<String> {
    let secret = rand_token("rsess_");
    let now = crate::now();
    c.execute(
        "INSERT INTO sessions(digest,user_id,created_at,expires_at) VALUES (?1,?2,?3,?4)",
        params![sha_hex(&secret), user_id, now, now + SESSION_SECS],
    )?;
    Ok(secret)
}

// ---------- principal ----------

#[derive(Clone, Debug)]
pub struct Principal {
    pub user_id: i64,
    pub tenant_id: String,
    pub role: String,
    /// `None` for sessions (role decides); `Some` for API tokens (scopes AND role decide).
    pub scopes: Option<Vec<String>>,
    pub token_id: Option<String>,
}

impl Principal {
    pub fn allows(&self, scope: &str, min_role: &str) -> bool {
        rank(&self.role) >= rank(min_role)
            && self
                .scopes
                .as_ref()
                .is_none_or(|s| s.iter().any(|x| x == scope))
    }
    pub fn require(&self, scope: &str, min_role: &str) -> Result<(), Response> {
        if self.allows(scope, min_role) {
            Ok(())
        } else {
            Err(err(403, "forbidden"))
        }
    }
}

fn cookie_val(h: &HeaderMap) -> Option<String> {
    h.get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|p| {
            p.trim()
                .strip_prefix(&format!("{COOKIE}="))
                .map(str::to_string)
        })
}
fn bare_host(h: &HeaderMap) -> Option<String> {
    h.get(header::HOST)?
        .to_str()
        .ok()
        .map(|v| v.split(':').next().unwrap_or(v).to_ascii_lowercase())
}

fn resolve(reg: &Registry, tok: &str, host: Option<&str>) -> Option<Principal> {
    let now = crate::now();
    let digest = sha_hex(tok);
    let c = reg.central.lock();
    if tok.starts_with("rupert_") {
        c.query_row(
            "SELECT t.id,t.tenant_id,t.user_id,t.scopes,t.expires_at,t.revoked_at,u.active,te.status,m.role
             FROM api_tokens t JOIN users u ON u.id=t.user_id JOIN tenants te ON te.id=t.tenant_id
             JOIN memberships m ON m.user_id=t.user_id AND m.tenant_id=t.tenant_id WHERE t.digest=?1",
            [&digest],
            |r| {
                let live = r.get::<_, Option<i64>>(5)?.is_none() && r.get::<_, Option<i64>>(4)?.is_none_or(|e| e > now)
                    && r.get::<_, i64>(6)? == 1 && r.get::<_, String>(7)? == "active";
                let scopes: Vec<String> = serde_json::from_str(&r.get::<_, String>(3)?).unwrap_or_default();
                let (uid, tid, role, id): (i64, String, String, String) = (r.get(2)?, r.get(1)?, r.get(8)?, r.get(0)?);
                Ok(live.then_some(Principal { user_id: uid, tenant_id: tid, role, scopes: Some(scopes), token_id: Some(id) }))
            },
        ).ok().flatten()
    } else if tok.starts_with("rsess_") {
        let (uid, active): (i64, i64) = c
            .query_row(
                "SELECT s.user_id,u.active FROM sessions s JOIN users u ON u.id=s.user_id
             WHERE s.digest=?1 AND s.revoked_at IS NULL AND s.expires_at>?2",
                params![digest, now],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .ok()?;
        if active != 1 {
            return None;
        }
        let tenant = host.and_then(|h| {
            c.query_row("SELECT tenant_id FROM domains WHERE host=?1", [h], |r| {
                r.get::<_, String>(0)
            })
            .ok()
        });
        let q = "SELECT m.tenant_id,m.role FROM memberships m JOIN tenants te ON te.id=m.tenant_id WHERE m.user_id=?1 AND te.status='active'";
        let rows: Vec<(String, String)> = c
            .prepare_cached(q)
            .ok()?
            .query_map([uid], |r| Ok((r.get(0)?, r.get(1)?)))
            .ok()?
            .flatten()
            .collect();
        let (t, role) = match tenant {
            Some(t) => rows.into_iter().find(|(x, _)| *x == t)?,
            None if rows.len() == 1 => rows.into_iter().next()?, // unambiguous without a host mapping
            None => return None,
        };
        Some(Principal {
            user_id: uid,
            tenant_id: t,
            role,
            scopes: None,
            token_id: None,
        })
    } else {
        None
    }
}

impl FromRequestParts<Arc<Registry>> for Principal {
    type Rejection = Response;
    async fn from_request_parts(parts: &mut Parts, reg: &Arc<Registry>) -> Result<Self, Response> {
        let tok = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::to_string)
            .or_else(|| cookie_val(&parts.headers))
            .ok_or_else(unauth)?;
        let host = tok
            .starts_with("rsess_")
            .then(|| bare_host(&parts.headers))
            .flatten();
        let key = format!("{}|{}", sha_hex(&tok), host.as_deref().unwrap_or(""));
        if let Some(p) = reg.auth.principals.get(&key) {
            return p.ok_or_else(unauth);
        }
        let (r, t, h) = (reg.clone(), tok, host);
        let p = tokio::task::spawn_blocking(move || resolve(&r, &t, h.as_deref()))
            .await
            .map_err(|_| err(500, "internal"))?;
        reg.auth.principals.insert(key, p.clone());
        p.ok_or_else(unauth)
    }
}

// ---------- handlers ----------

fn valid_email(e: &str) -> bool {
    e.len() <= 254
        && e.len() >= 5
        && e.matches('@').count() == 1
        && !e.starts_with('@')
        && !e.ends_with('@')
        && !e.contains(char::is_whitespace)
}
fn valid_pw(p: &str) -> bool {
    (12..=128).contains(&p.chars().count())
}
fn valid_slug(s: &str) -> bool {
    (3..=40).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !s.starts_with('-')
        && !s.ends_with('-')
        && !["www", "api", "admin", "app", "mail", "static"].contains(&s)
}

#[derive(Deserialize)]
struct Signup {
    email: String,
    password: String,
    org_name: String,
    subdomain: String,
    name: Option<String>,
    signup_code: Option<String>,
}

async fn signup(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Json(b): Json<Signup>,
) -> R {
    limit(&reg, format!("signup|{}", client_key(&reg, ci, &h)), 5)?;
    if !reg.auth.signup_open {
        // Closed by default: only a caller holding the shared code may create an organization.
        let ok = match (&reg.auth.signup_code, &b.signup_code) {
            (Some(want), Some(got)) => ct_eq(want.as_bytes(), sha_hex(got).as_bytes()),
            _ => false,
        };
        if !ok {
            return Err(err(403, "signups are closed"));
        }
    }
    let email = b.email.trim().to_ascii_lowercase();
    if !valid_email(&email) {
        return Err(err(400, "invalid email"));
    }
    if !valid_pw(&b.password) {
        return Err(err(400, "password must be 12-128 characters"));
    }
    if b.org_name.trim().is_empty() || b.org_name.len() > 100 {
        return Err(err(400, "invalid organization name"));
    }
    if !valid_slug(&b.subdomain) {
        return Err(err(400, "subdomain must be 3-40 chars of a-z, 0-9, '-'"));
    }
    let pw = hash_async(&reg, b.password).await?;
    let b_sub = b.subdomain.clone();
    let host = format!("{}.{}", b.subdomain, reg.auth.base_domain);
    let r2 = reg.clone();
    let out = tokio::task::spawn_blocking(move || -> Result<(String, String), Response> {
        let mut c = r2.central.lock();
        let tx = c.transaction().map_err(dberr)?;
        let now = crate::now();
        tx.execute(
            "INSERT INTO users(email,pw_hash,name,active,created_at) VALUES (?1,?2,?3,1,?4)",
            params![email, pw, b.name.unwrap_or_default(), now],
        )
        .map_err(|e| {
            if e.to_string().contains("UNIQUE") {
                err(409, "an account with this email already exists")
            } else {
                dberr(e)
            }
        })?;
        let uid = tx.last_insert_rowid();
        let tid = rand_id("t_");
        tx.execute(
            "INSERT INTO tenants(id,name,created_at) VALUES (?1,?2,?3)",
            params![tid, b.org_name.trim(), now],
        )
        .map_err(dberr)?;
        tx.execute(
            "INSERT INTO domains(host,tenant_id) VALUES (?1,?2)",
            params![host, tid],
        )
        .map_err(|e| {
            if e.to_string().contains("UNIQUE") {
                err(409, "subdomain is taken")
            } else {
                dberr(e)
            }
        })?;
        tx.execute(
            "INSERT INTO memberships VALUES (?1,?2,'owner')",
            params![uid, tid],
        )
        .map_err(dberr)?;
        let sess = new_session(&tx, uid).map_err(dberr)?;
        audit(&tx, Some(&tid), Some(uid), "signup", &host);
        tx.commit().map_err(dberr)?;
        Ok((tid, sess))
    })
    .await
    .map_err(|_| err(500, "internal"))??;
    let (tid, sess) = out;
    let host = format!("{}.{}", b_sub, reg.auth.base_domain);
    let r3 = reg.clone();
    let tid2 = tid.clone();
    tokio::task::spawn_blocking(move || r3.db(&tid2).map(|_| ()))
        .await
        .ok();
    let body = json!({ "tenant_id": tid, "host": host, "session_token": sess });
    Ok(with_cookie(
        (StatusCode::CREATED, Json(body)).into_response(),
        &reg.auth,
        &sess,
    ))
}

#[derive(Deserialize)]
struct Login {
    email: String,
    password: String,
}

async fn login(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Json(b): Json<Login>,
) -> R {
    let email = b.email.trim().to_ascii_lowercase();
    limit(&reg, format!("login|ip|{}", client_key(&reg, ci, &h)), 20)?;
    limit(&reg, format!("login|em|{email}"), 10)?;
    let r2 = reg.clone();
    let e2 = email.clone();
    let row: Option<(i64, String, i64)> = tokio::task::spawn_blocking(move || {
        r2.central
            .lock()
            .query_row(
                "SELECT id,pw_hash,active FROM users WHERE email=?1",
                [&e2],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .ok()
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    // Verify against a dummy hash when the user is unknown so timing does not reveal accounts.
    let (uid, hash, active) = row.clone().unwrap_or((0, reg.auth.dummy_hash.clone(), 0));
    let good = verify_async(&reg, b.password, hash).await && row.is_some() && active == 1;
    let r3 = reg.clone();
    let res =
        tokio::task::spawn_blocking(move || -> Result<Option<(String, Vec<Value>)>, Response> {
            let c = r3.central.lock();
            if !good {
                audit(
                    &c,
                    None,
                    None,
                    "login_failed",
                    &email.chars().take(100).collect::<String>(),
                );
                return Ok(None);
            }
            let s = new_session(&c, uid).map_err(dberr)?;
            audit(&c, None, Some(uid), "login", "");
            let ms = memberships(&c, uid);
            Ok(Some((s, ms)))
        })
        .await
        .map_err(|_| err(500, "internal"))??;
    match res {
        None => Err(err(401, "invalid email or password")),
        Some((s, ms)) => Ok(with_cookie(
            (
                StatusCode::OK,
                Json(json!({ "session_token": s, "memberships": ms })),
            )
                .into_response(),
            &reg.auth,
            &s,
        )),
    }
}

fn memberships(c: &Connection, uid: i64) -> Vec<Value> {
    c.prepare_cached("SELECT m.tenant_id,t.name,m.role FROM memberships m JOIN tenants t ON t.id=m.tenant_id WHERE m.user_id=?1")
        .and_then(|mut s| s.query_map([uid], |r| Ok(json!({ "tenant_id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?, "role": r.get::<_, String>(2)? }))).map(|i| i.flatten().collect()))
        .unwrap_or_default()
}

#[derive(Deserialize)]
struct ChangePassword {
    current_password: String,
    new_password: String,
}

/// Signed-in users change their own password. All of their other sessions are signed out; API tokens are
/// unaffected (revoke them separately if the password was compromised).
async fn change_password(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
    Json(b): Json<ChangePassword>,
) -> R {
    if p.token_id.is_some() {
        return Err(err(
            403,
            "passwords are changed by signed-in users, not tokens",
        ));
    }
    limit(&reg, format!("pwchange|{}", p.user_id), 10)?;
    if !valid_pw(&b.new_password) {
        return Err(err(400, "password must be 12-128 characters"));
    }
    if b.new_password == b.current_password {
        return Err(err(
            400,
            "the new password must differ from the current one",
        ));
    }
    let (r2, uid) = (reg.clone(), p.user_id);
    let hash: String = tokio::task::spawn_blocking(move || {
        r2.central
            .lock()
            .query_row("SELECT pw_hash FROM users WHERE id=?1", [uid], |r| r.get(0))
            .ok()
    })
    .await
    .map_err(|_| err(500, "internal"))?
    .ok_or_else(|| err(404, "not found"))?;
    if !verify_async(&reg, b.current_password, hash).await {
        let r3 = reg.clone();
        let t = p.tenant_id.clone();
        tokio::task::spawn_blocking(move || {
            audit(
                &r3.central.lock(),
                Some(&t),
                Some(uid),
                "password_change_failed",
                "",
            )
        })
        .await
        .ok();
        return Err(err(401, "current password is incorrect"));
    }
    let new_hash = hash_async(&reg, b.new_password).await?;
    let current = h
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string)
        .or_else(|| cookie_val(&h))
        .map(|t| sha_hex(&t))
        .unwrap_or_default();
    let (r4, t4) = (reg.clone(), p.tenant_id.clone());
    tokio::task::spawn_blocking(move || {
        let c = r4.central.lock();
        let _ = c.execute("UPDATE users SET pw_hash=?2 WHERE id=?1", params![uid, new_hash]);
        let _ = c.execute(
            "UPDATE sessions SET revoked_at=?3 WHERE user_id=?1 AND digest<>?2 AND revoked_at IS NULL",
            params![uid, current, crate::now()],
        );
        audit(&c, Some(&t4), Some(uid), "password_change", "");
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    reg.auth.principals.invalidate_all();
    ok(json!({ "changed": true }))
}

async fn logout(State(reg): State<Arc<Registry>>, h: HeaderMap) -> R {
    let tok = h
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string)
        .or_else(|| cookie_val(&h))
        .ok_or_else(unauth)?;
    let r2 = reg.clone();
    tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        let _ = c.execute(
            "UPDATE sessions SET revoked_at=?2 WHERE digest=?1 AND revoked_at IS NULL",
            params![sha_hex(&tok), crate::now()],
        );
    })
    .await
    .ok();
    reg.auth.principals.invalidate_all();
    let mut r = (StatusCode::OK, Json(json!({ "ok": true }))).into_response();
    r.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&format!("{COOKIE}=; HttpOnly; Path=/; Max-Age=0")).unwrap(),
    );
    Ok(r)
}

async fn me(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    let r2 = reg.clone();
    let uid = p.user_id;
    let (email, ms) = tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        (
            c.query_row("SELECT email FROM users WHERE id=?1", [uid], |r| {
                r.get::<_, String>(0)
            })
            .unwrap_or_default(),
            memberships(&c, uid),
        )
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    ok(
        json!({ "user_id": p.user_id, "email": email, "tenant_id": p.tenant_id, "role": p.role, "scopes": p.scopes, "memberships": ms }),
    )
}

#[derive(Deserialize)]
struct NewToken {
    name: String,
    scopes: Vec<String>,
    expires_in_days: Option<i64>,
}

async fn create_token(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Json(b): Json<NewToken>,
) -> R {
    // Tokens are minted by people, not by other tokens.
    if p.token_id.is_some() {
        return Err(err(403, "a token cannot create tokens"));
    }
    p.require("tokens:write", "manager")?;
    if b.name.trim().is_empty() || b.name.len() > 100 {
        return Err(err(400, "invalid name"));
    }
    if b.scopes.is_empty() || b.scopes.iter().any(|s| !SCOPES.contains(&s.as_str())) {
        return Err(err(400, "invalid scopes"));
    }
    if b.scopes.iter().any(|s| s == "inventory:write") && rank(&p.role) < 2 {
        return Err(err(403, "inventory:write requires manager or owner"));
    }
    let days = b.expires_in_days.unwrap_or(90);
    if !(1..=730).contains(&days) {
        return Err(err(400, "expires_in_days must be 1-730"));
    }
    let secret = rand_token("rupert_");
    let (id, now) = (rand_id("tok_"), crate::now());
    let hint = format!("rupert_...{}", &secret[secret.len() - 6..]);
    let (r2, p2, d2, id2, name) = (
        reg.clone(),
        p.clone(),
        sha_hex(&secret),
        id.clone(),
        b.name.trim().to_string(),
    );
    let scopes = serde_json::to_string(&b.scopes).unwrap();
    let hint2 = hint.clone();
    tokio::task::spawn_blocking(move || -> Result<(), Response> {
        let c = r2.central.lock();
        c.execute(
            "INSERT INTO api_tokens VALUES (?1,?2,?3,?4,?5,?6,?7,?8,NULL,?9)",
            params![
                id2,
                p2.tenant_id,
                p2.user_id,
                name,
                d2,
                hint2,
                scopes,
                now + days * 86400,
                now
            ],
        )
        .map_err(dberr)?;
        audit(
            &c,
            Some(&p2.tenant_id),
            Some(p2.user_id),
            "token_create",
            &id2,
        );
        Ok(())
    })
    .await
    .map_err(|_| err(500, "internal"))??;
    created(
        json!({ "id": id, "token": secret, "hint": hint, "scopes": b.scopes, "expires_at": now + days * 86400, "note": "shown once; store it in a secret manager" }),
    )
}

async fn list_tokens(State(reg): State<Arc<Registry>>, p: Principal) -> R {
    p.require("tokens:read", "manager")?;
    let r2 = reg.clone();
    let rows = tokio::task::spawn_blocking(move || -> Vec<Value> {
        let c = r2.central.lock();
        // Owners see every token in the tenant; managers only their own.
        let all = rank(&p.role) >= 3;
        c.prepare_cached("SELECT id,user_id,name,hint,scopes,expires_at,revoked_at,created_at FROM api_tokens WHERE tenant_id=?1 AND (?2 OR user_id=?3) ORDER BY created_at DESC LIMIT 200")
            .and_then(|mut s| s.query_map(params![p.tenant_id, all, p.user_id], |r| Ok(json!({
                "id": r.get::<_, String>(0)?, "user_id": r.get::<_, i64>(1)?, "name": r.get::<_, String>(2)?, "hint": r.get::<_, String>(3)?,
                "scopes": serde_json::from_str::<Value>(&r.get::<_, String>(4)?).unwrap_or(Value::Null),
                "expires_at": r.get::<_, Option<i64>>(5)?, "revoked_at": r.get::<_, Option<i64>>(6)?, "created_at": r.get::<_, i64>(7)? }))).map(|i| i.flatten().collect()))
            .unwrap_or_default()
    }).await.map_err(|_| err(500, "internal"))?;
    ok(json!({ "data": rows }))
}

async fn revoke_token(State(reg): State<Arc<Registry>>, p: Principal, Path(id): Path<String>) -> R {
    p.require("tokens:write", "manager")?;
    let r2 = reg.clone();
    let n = tokio::task::spawn_blocking(move || {
        let c = r2.central.lock();
        let all = rank(&p.role) >= 3;
        let n = c.execute("UPDATE api_tokens SET revoked_at=?4 WHERE id=?1 AND tenant_id=?2 AND revoked_at IS NULL AND (?5 OR user_id=?3)", params![id, p.tenant_id, p.user_id, crate::now(), all]).unwrap_or(0);
        if n > 0 { audit(&c, Some(&p.tenant_id), Some(p.user_id), "token_revoke", &id); }
        n
    }).await.map_err(|_| err(500, "internal"))?;
    reg.auth.principals.invalidate_all(); // revocation applies to the very next request
    if n == 0 {
        Err(err(404, "not found"))
    } else {
        ok(json!({ "revoked": true }))
    }
}

#[derive(Deserialize)]
struct NewInvite {
    email: String,
    role: String,
}

async fn create_invite(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    Json(b): Json<NewInvite>,
) -> R {
    if p.token_id.is_some() {
        return Err(err(403, "a token cannot create invites"));
    }
    let email = b.email.trim().to_ascii_lowercase();
    if !valid_email(&email) {
        return Err(err(400, "invalid email"));
    }
    // Owners invite managers or staff; managers invite staff only. Nobody can mint owners.
    let need = match b.role.as_str() {
        "staff" => "manager",
        "manager" => "owner",
        _ => return Err(err(400, "role must be staff or manager")),
    };
    p.require("invites:write", need)?;
    let secret = rand_token("rinv_");
    let (r2, d, now) = (reg.clone(), sha_hex(&secret), crate::now());
    let (p2, e2, role) = (p.clone(), email.clone(), b.role.clone());
    tokio::task::spawn_blocking(move || -> Result<(), Response> {
        let c = r2.central.lock();
        c.execute(
            "INSERT INTO invites VALUES (?1,?2,?3,?4,?5,?6,NULL)",
            params![d, p2.tenant_id, e2, role, p2.user_id, now + 7 * 86400],
        )
        .map_err(dberr)?;
        audit(
            &c,
            Some(&p2.tenant_id),
            Some(p2.user_id),
            "invite_create",
            &format!("{e2} {role}"),
        );
        Ok(())
    })
    .await
    .map_err(|_| err(500, "internal"))??;
    created(
        json!({ "invite_token": secret, "email": email, "role": b.role, "expires_in_days": 7, "note": "deliver to the invitee out of band; shown once" }),
    )
}

#[derive(Deserialize)]
struct Accept {
    token: String,
    password: String,
    name: Option<String>,
}

async fn accept_invite(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Json(b): Json<Accept>,
) -> R {
    limit(&reg, format!("accept|{}", client_key(&reg, ci, &h)), 10)?;
    if !valid_pw(&b.password) {
        return Err(err(400, "password must be 12-128 characters"));
    }
    let digest = sha_hex(&b.token);
    let r1 = reg.clone();
    let inv: Option<(String, String, String)> = tokio::task::spawn_blocking(move || {
        r1.central.lock().query_row("SELECT tenant_id,email,role FROM invites WHERE digest=?1 AND accepted_at IS NULL AND expires_at>?2", params![digest, crate::now()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).ok()
    }).await.map_err(|_| err(500, "internal"))?;
    let (tid, email, role) = inv.ok_or_else(|| err(404, "invite not found or expired"))?;
    // An existing account must prove itself with its password; a new one sets it now.
    let r2 = reg.clone();
    let e2 = email.clone();
    let existing: Option<(i64, String)> = tokio::task::spawn_blocking(move || {
        r2.central
            .lock()
            .query_row("SELECT id,pw_hash FROM users WHERE email=?1", [&e2], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .ok()
    })
    .await
    .map_err(|_| err(500, "internal"))?;
    let (known_uid, new_hash) = match existing {
        Some((uid, hash)) => {
            if !verify_async(&reg, b.password.clone(), hash).await {
                return Err(err(401, "invalid password for the invited account"));
            }
            (Some(uid), String::new())
        }
        None => (None, hash_async(&reg, b.password.clone()).await?),
    };
    let r3 = reg.clone();
    let digest = sha_hex(&b.token);
    let name = b.name.unwrap_or_default();
    let sess = tokio::task::spawn_blocking(move || -> Result<String, Response> {
        let mut c = r3.central.lock();
        let tx = c.transaction().map_err(dberr)?;
        let now = crate::now();
        // Claim the invite first; a concurrent accept loses here.
        if tx.execute("UPDATE invites SET accepted_at=?2 WHERE digest=?1 AND accepted_at IS NULL", params![digest, now]).map_err(dberr)? == 0 { return Err(err(409, "invite already used")); }
        let uid = match known_uid {
            Some(u) => u,
            None => { tx.execute("INSERT INTO users(email,pw_hash,name,active,created_at) VALUES (?1,?2,?3,1,?4)", params![email, new_hash, name, now]).map_err(dberr)?; tx.last_insert_rowid() }
        };
        tx.execute("INSERT OR IGNORE INTO memberships VALUES (?1,?2,?3)", params![uid, tid, role]).map_err(dberr)?;
        let s = new_session(&tx, uid).map_err(dberr)?;
        audit(&tx, Some(&tid), Some(uid), "invite_accept", &role);
        tx.commit().map_err(dberr)?;
        Ok(s)
    }).await.map_err(|_| err(500, "internal"))??;
    Ok(with_cookie(
        (StatusCode::CREATED, Json(json!({ "session_token": sess }))).into_response(),
        &reg.auth,
        &sess,
    ))
}

pub fn routes() -> Router<Arc<Registry>> {
    Router::new()
        .route("/auth/signup", post(signup))
        .route("/auth/login", post(login))
        .route("/auth/logout", post(logout))
        .route("/auth/invites/accept", post(accept_invite))
        .route("/api/v1/me", get(me))
        .route("/api/v1/me/password", post(change_password))
        .route("/api/v1/tokens", get(list_tokens).post(create_token))
        .route("/api/v1/tokens/{id}", delete(revoke_token))
        .route("/api/v1/invites", post(create_invite))
        .layer(axum::middleware::from_fn(no_store))
}
