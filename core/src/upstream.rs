//! Read-only clients for Shopify and Square. Every call passes an explicit
//! allowlist check before it is sent, so a code change cannot start writing to
//! either platform without also editing (and testing) the allowlist. Writes to
//! Shopify or Square need the owner's explicit sign-off (see AGENTS.md).
use serde_json::{Value, json};
use std::time::Duration;

pub const SHOPIFY_API_VERSION: &str = "2026-07";
pub const SQUARE_VERSION: &str = "2026-07-15";

pub fn check_graphql(q: &str) -> Result<(), String> {
    let l = q.to_ascii_lowercase();
    if l.contains("mutation") || l.contains("subscription") { Err("read-only client: GraphQL mutations are not allowed".into()) } else { Ok(()) }
}

pub fn check_square(method: &str, path: &str) -> Result<(), String> {
    match (method, path.split('?').next().unwrap_or(path)) {
        ("GET", "/locations") | ("GET", "/catalog/list") | ("POST", "/inventory/counts/batch-retrieve") => Ok(()),
        _ => Err(format!("read-only client: {method} {path} is not allowlisted")),
    }
}

pub fn valid_shop_domain(d: &str) -> bool {
    d.strip_suffix(".myshopify.com").is_some_and(|h| !h.is_empty() && h.len() <= 60 && h.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') && !h.starts_with('-'))
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(60))).http_status_as_error(false).build().into()
}

/// One request with bounded retry on 429/503 (honours Retry-After, capped at 10 s).
fn call(agent: &ureq::Agent, method: &str, url: &str, headers: &[(&str, &str)], body: Option<&Value>) -> Result<(u16, Value), String> {
    for attempt in 0..5u32 {
        let res = match (method, body) {
            ("GET", _) => { let mut r = agent.get(url); for (k, v) in headers { r = r.header(*k, *v); } r.call() }
            (_, Some(b)) => { let mut r = agent.post(url); for (k, v) in headers { r = r.header(*k, *v); } r.send_json(b) }
            _ => return Err("unsupported request".into()),
        };
        let mut resp = match res {
            Ok(r) => r,
            // A pooled keep-alive connection the server already closed fails the first write.
            // Every call this client can make is a read (see the allowlist), so retrying is safe.
            Err(_) if attempt < 3 => { std::thread::sleep(Duration::from_millis(200 * (attempt as u64 + 1))); continue; }
            Err(e) => return Err(format!("network error: {e}")),
        };
        let status = resp.status().as_u16();
        if (status == 429 || status == 503) && attempt < 4 {
            let wait = resp.headers().get("retry-after").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(1 << attempt).min(10);
            std::thread::sleep(Duration::from_secs(wait));
            continue;
        }
        let v: Value = resp.body_mut().read_json().unwrap_or(Value::Null);
        return Ok((status, v));
    }
    Err("rate limited after retries".into())
}

/// Evidence that only reads were sent: one stderr line per upstream call, enabled with
/// RUPERT_LOG_UPSTREAM=1. Method, host-less path without query string, GraphQL operation name
/// and status only; never bodies, tokens or secrets.
fn ledger(method: &str, url: &str, op: Option<&str>, status: u16) {
    if std::env::var("RUPERT_LOG_UPSTREAM").is_err() { return; }
    let path = url.split("://").nth(1).and_then(|r| r.find('/').map(|i| &r[i..])).unwrap_or(url);
    eprintln!("upstream {method} {} {} -> {status}", path.split('?').next().unwrap_or(path), op.unwrap_or("-"));
}

fn gql_op(q: &str) -> &str { q.split_whitespace().nth(1).map(|w| w.split(|c: char| !c.is_alphanumeric()).next().unwrap_or("")).unwrap_or("") }

fn short(v: &Value) -> String { v.to_string().chars().take(300).collect() }

// ---------- Shopify ----------

pub struct Shopify { agent: ureq::Agent, base: String, client_id: String, secret: String, token: Option<String> }

pub struct ShopifyVariant { pub id: String, pub product_id: String, pub title: String, pub sku: Option<String>, pub price: Option<f64>, pub inventory_item_id: Option<String>, pub qty: i64, pub tracked: bool }

const PRODUCTS_QUERY: &str = "query Products($cursor: String) { products(first: 250, query: \"status:active\", sortKey: TITLE, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id title variants(first: 100) { pageInfo { hasNextPage endCursor } nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } } } } }";
const VARIANTS_QUERY: &str = "query ProductVariants($id: ID!, $cursor: String) { product(id: $id) { variants(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } } } }";

impl Shopify {
    pub fn new(base: String, client_id: String, secret: String) -> Self { Self { agent: agent(), base, client_id, secret, token: None } }

    fn token(&mut self) -> Result<String, String> {
        if let Some(t) = &self.token { return Ok(t.clone()); }
        // Client-credentials exchange: authenticates this app, changes nothing in the shop.
        let body = json!({ "client_id": self.client_id, "client_secret": self.secret, "grant_type": "client_credentials" });
        let url = format!("{}/admin/oauth/access_token", self.base);
        let (s, v) = call(&self.agent, "POST", &url, &[], Some(&body))?;
        ledger("POST", &url, Some("token_exchange"), s);
        if s != 200 { return Err(format!("Shopify token exchange failed ({s})")); }
        let t = v["access_token"].as_str().ok_or("Shopify token exchange returned no access_token")?.to_string();
        self.token = Some(t.clone());
        Ok(t)
    }

    fn graphql(&mut self, query: &str, vars: Value) -> Result<Value, String> {
        check_graphql(query)?;
        let t = self.token()?;
        let url = format!("{}/admin/api/{SHOPIFY_API_VERSION}/graphql.json", self.base);
        let (s, v) = call(&self.agent, "POST", &url, &[("X-Shopify-Access-Token", &t)], Some(&json!({ "query": query, "variables": vars })))?;
        ledger("POST", &url, Some(gql_op(query)), s);
        if s != 200 { return Err(format!("Shopify GraphQL failed ({s})")); }
        if let Some(e) = v.get("errors").filter(|e| !e.is_null()) { return Err(format!("Shopify GraphQL errors: {}", short(e))); }
        Ok(v["data"].clone())
    }

    /// Streams active products' variants page by page (follows every cursor).
    pub fn variants(&mut self, mut sink: impl FnMut(Vec<ShopifyVariant>) -> Result<(), String>) -> Result<(), String> {
        let mut cursor = Value::Null;
        loop {
            let data = self.graphql(PRODUCTS_QUERY, json!({ "cursor": cursor }))?;
            let page = &data["products"];
            let mut out = Vec::new();
            for p in page["nodes"].as_array().into_iter().flatten() {
                let pid = p["id"].as_str().unwrap_or_default().to_string();
                let mut nodes: Vec<Value> = p["variants"]["nodes"].as_array().cloned().unwrap_or_default();
                let mut vc = p["variants"]["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false).then(|| p["variants"]["pageInfo"]["endCursor"].clone());
                while let Some(c) = vc.take() {
                    let d = self.graphql(VARIANTS_QUERY, json!({ "id": pid, "cursor": c }))?;
                    let vv = &d["product"]["variants"];
                    nodes.extend(vv["nodes"].as_array().cloned().unwrap_or_default());
                    if vv["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) { vc = Some(vv["pageInfo"]["endCursor"].clone()); }
                }
                for n in nodes {
                    out.push(ShopifyVariant {
                        id: n["id"].as_str().unwrap_or_default().into(), product_id: pid.clone(), title: n["title"].as_str().unwrap_or_default().into(),
                        sku: n["sku"].as_str().filter(|s| !s.is_empty()).map(String::from),
                        price: n["price"].as_str().and_then(|s| s.parse().ok()).or(n["price"].as_f64()),
                        inventory_item_id: n["inventoryItem"]["id"].as_str().map(String::from),
                        qty: n["inventoryQuantity"].as_i64().unwrap_or(0), tracked: n["inventoryItem"]["tracked"].as_bool().unwrap_or(false),
                    });
                }
            }
            sink(out)?;
            if page["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) { cursor = page["pageInfo"]["endCursor"].clone(); } else { return Ok(()); }
        }
    }
}

// ---------- Square ----------

pub struct Square { agent: ureq::Agent, base: String, token: String }

pub struct SquareVariation { pub id: String, pub item_id: String, pub name: String, pub sku: Option<String> }

impl Square {
    pub fn new(base: String, token: String) -> Self { Self { agent: agent(), base, token } }

    fn req(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        check_square(method, path)?;
        let auth = format!("Bearer {}", self.token);
        let url = format!("{}{path}", self.base);
        let (s, v) = call(&self.agent, method, &url, &[("Authorization", &auth), ("Square-Version", SQUARE_VERSION)], body.as_ref())?;
        ledger(method, &url, None, s);
        if s != 200 {
            let d = v["errors"].as_array().map(|a| a.iter().filter_map(|e| e["detail"].as_str()).collect::<Vec<_>>().join("; ")).unwrap_or_default();
            return Err(format!("Square {method} {} failed ({s}) {d}", path.split('?').next().unwrap_or(path)));
        }
        Ok(v)
    }

    pub fn locations(&self) -> Result<Vec<String>, String> {
        let v = self.req("GET", "/locations", None)?;
        Ok(v["locations"].as_array().into_iter().flatten().filter(|l| l["status"] == "ACTIVE").filter_map(|l| l["id"].as_str().map(String::from)).collect())
    }

    pub fn catalog(&self, mut sink: impl FnMut(Vec<SquareVariation>) -> Result<(), String>) -> Result<(), String> {
        let mut cursor: Option<String> = None;
        loop {
            let path = match &cursor { Some(c) => format!("/catalog/list?types=ITEM&limit=1000&cursor={}", enc(c)), None => "/catalog/list?types=ITEM&limit=1000".into() };
            let v = self.req("GET", &path, None)?;
            let mut out = Vec::new();
            for o in v["objects"].as_array().into_iter().flatten() {
                if o["type"] != "ITEM" || o["is_deleted"].as_bool().unwrap_or(false) { continue; }
                let item_name = o["item_data"]["name"].as_str().unwrap_or("Untitled item");
                for var in o["item_data"]["variations"].as_array().into_iter().flatten() {
                    if var["is_deleted"].as_bool().unwrap_or(false) { continue; }
                    out.push(SquareVariation {
                        id: var["id"].as_str().unwrap_or_default().into(), item_id: o["id"].as_str().unwrap_or_default().into(),
                        name: var["item_variation_data"]["name"].as_str().unwrap_or(item_name).into(),
                        sku: var["item_variation_data"]["sku"].as_str().filter(|s| !s.is_empty()).map(String::from),
                    });
                }
            }
            sink(out)?;
            cursor = v["cursor"].as_str().filter(|c| !c.is_empty()).map(String::from);
            if cursor.is_none() { return Ok(()); }
        }
    }

    /// (variation id, location id, in-stock quantity) for up to 100 variations at a time.
    pub fn counts(&self, locations: &[String], ids: &[String]) -> Result<Vec<(String, String, i64)>, String> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut body = json!({ "location_ids": locations, "catalog_object_ids": ids, "states": ["IN_STOCK"] });
            if let Some(c) = &cursor { body["cursor"] = json!(c); }
            let v = self.req("POST", "/inventory/counts/batch-retrieve", Some(body))?;
            for c in v["counts"].as_array().into_iter().flatten() {
                if c["state"].as_str().is_some_and(|s| s != "IN_STOCK") { continue; }
                let q = c["quantity"].as_str().and_then(|q| q.parse::<f64>().ok()).or(c["quantity"].as_f64());
                if let (Some(q), Some(id), Some(loc)) = (q, c["catalog_object_id"].as_str(), c["location_id"].as_str()) { out.push((id.into(), loc.into(), q as i64)); }
            }
            cursor = v["cursor"].as_str().filter(|c| !c.is_empty()).map(String::from);
            if cursor.is_none() { return Ok(out); }
        }
    }
}

fn enc(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn graphql_mutations_rejected() {
        assert!(check_graphql("query Q { shop { name } }").is_ok());
        assert!(check_graphql("mutation { productDelete(input:{id:\"x\"}) { deletedProductId } }").is_err());
        assert!(check_graphql("MUTATION{x}").is_err());
        assert!(check_graphql("subscription { x }").is_err());
    }
    #[test]
    fn square_allowlist() {
        assert!(check_square("GET", "/locations").is_ok());
        assert!(check_square("GET", "/catalog/list?types=ITEM").is_ok());
        assert!(check_square("POST", "/inventory/counts/batch-retrieve").is_ok());
        for (m, p) in [("POST", "/catalog/upsert"), ("POST", "/inventory/changes/batch-create"), ("DELETE", "/catalog/object/X"), ("PUT", "/locations"), ("POST", "/orders"), ("GET", "/payments")] {
            assert!(check_square(m, p).is_err(), "{m} {p}");
        }
    }
    #[test]
    fn shop_domain() {
        assert!(valid_shop_domain("my-shop.myshopify.com"));
        for d in ["evil.com", "a.myshopify.com.evil.com", ".myshopify.com", "My.myshopify.com", "a/b.myshopify.com", "http://x.myshopify.com"] { assert!(!valid_shop_domain(d), "{d}"); }
    }
}
