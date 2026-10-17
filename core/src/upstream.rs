//! Read-only clients for Shopify and Square. Every call passes an explicit
//! allowlist check before it is sent, so a code change cannot start writing to
//! either platform without also editing (and testing) the allowlist. Writes to
//! Shopify or Square need the owner's explicit sign-off (see AGENTS.md).
use serde_json::{Value, json};
use std::time::Duration;

pub const SHOPIFY_API_VERSION: &str = "2026-07";
pub const SQUARE_VERSION: &str = "2026-07-15";

/// Per-operation counters for one provider. `requests` counts every HTTP attempt (retries included).
#[derive(Default, Clone)]
pub struct OpStat {
    pub requests: u64,
    pub throttled: u64,
    pub retries: u64,
    pub errors: u64,
    pub wait_ms: u64,
}

/// Counts every upstream call so we can see how hard we lean on a provider, and stops a run that is
/// making far more calls than any sane catalog needs (a loop or a pagination bug).
pub struct Meter {
    cap: u64,
    total: u64,
    pub ops: std::collections::BTreeMap<String, OpStat>,
}
pub type SharedMeter = std::sync::Arc<parking_lot::Mutex<Meter>>;

impl Meter {
    pub fn shared(cap: u64) -> SharedMeter {
        std::sync::Arc::new(parking_lot::Mutex::new(Meter {
            cap,
            total: 0,
            ops: Default::default(),
        }))
    }
    fn hit(&mut self, op: &str) -> Result<(), String> {
        if self.total >= self.cap {
            return Err(format!(
                "request cap of {} reached for this run (possible loop); aborting to protect the provider's API",
                self.cap
            ));
        }
        self.total += 1;
        self.ops.entry(op.to_string()).or_default().requests += 1;
        Ok(())
    }
    fn op(&mut self, op: &str) -> &mut OpStat {
        self.ops.entry(op.to_string()).or_default()
    }
    pub fn snapshot(&self) -> Value {
        let sum = |f: fn(&OpStat) -> u64| self.ops.values().map(f).sum::<u64>();
        json!({ "requests": sum(|o| o.requests), "throttled": sum(|o| o.throttled), "retries": sum(|o| o.retries), "errors": sum(|o| o.errors), "wait_ms": sum(|o| o.wait_ms),
                "by_op": self.ops.iter().map(|(k, v)| (k.clone(), json!(v.requests))).collect::<serde_json::Map<_, _>>() })
    }
}

pub fn check_graphql(q: &str) -> Result<(), String> {
    let l = q.to_ascii_lowercase();
    if l.contains("mutation") || l.contains("subscription") {
        Err("read-only client: GraphQL mutations are not allowed".into())
    } else {
        Ok(())
    }
}

pub fn check_square(method: &str, path: &str) -> Result<(), String> {
    match (method, path.split('?').next().unwrap_or(path)) {
        ("GET", "/locations")
        | ("GET", "/catalog/list")
        | ("POST", "/inventory/counts/batch-retrieve")
        | ("POST", "/orders/search")
        | ("POST", "/orders/batch-retrieve") => Ok(()),
        _ => Err(format!(
            "read-only client: {method} {path} is not allowlisted"
        )),
    }
}

pub fn valid_shop_domain(d: &str) -> bool {
    d.strip_suffix(".myshopify.com").is_some_and(|h| {
        !h.is_empty()
            && h.len() <= 60
            && h.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && !h.starts_with('-')
    })
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(60)))
        .http_status_as_error(false)
        .build()
        .into()
}

/// One request with bounded retry on 429/503 (honours Retry-After, capped at 10 s) and on stale pooled
/// connections. Every attempt is counted in the meter under `op`.
fn call(
    agent: &ureq::Agent,
    meter: &SharedMeter,
    op: &str,
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: Option<&Value>,
) -> Result<(u16, Value), String> {
    for attempt in 0..5u32 {
        meter.lock().hit(op)?;
        let res = match (method, body) {
            ("GET", _) => {
                let mut r = agent.get(url);
                for (k, v) in headers {
                    r = r.header(*k, *v);
                }
                r.call()
            }
            (_, Some(b)) => {
                let mut r = agent.post(url);
                for (k, v) in headers {
                    r = r.header(*k, *v);
                }
                r.send_json(b)
            }
            _ => return Err("unsupported request".into()),
        };
        let mut resp = match res {
            Ok(r) => r,
            // A pooled keep-alive connection the server already closed fails the first write.
            // Every call this client can make is a read (see the allowlist), so retrying is safe.
            Err(_) if attempt < 3 => {
                let wait = 200 * (attempt as u64 + 1);
                {
                    let mut m = meter.lock();
                    let o = m.op(op);
                    o.errors += 1;
                    o.retries += 1;
                    o.wait_ms += wait;
                }
                std::thread::sleep(Duration::from_millis(wait));
                continue;
            }
            Err(e) => {
                meter.lock().op(op).errors += 1;
                return Err(format!("network error: {e}"));
            }
        };
        let status = resp.status().as_u16();
        if (status == 429 || status == 503) && attempt < 4 {
            let wait = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(1 << attempt)
                .min(10);
            {
                let mut m = meter.lock();
                let o = m.op(op);
                o.throttled += 1;
                o.retries += 1;
                o.wait_ms += wait * 1000;
            }
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
    if std::env::var("RUPERT_LOG_UPSTREAM").is_err() {
        return;
    }
    let path = url
        .split("://")
        .nth(1)
        .and_then(|r| r.find('/').map(|i| &r[i..]))
        .unwrap_or(url);
    eprintln!(
        "upstream {method} {} {} -> {status}",
        path.split('?').next().unwrap_or(path),
        op.unwrap_or("-")
    );
}

fn gql_op(q: &str) -> &str {
    q.split_whitespace()
        .nth(1)
        .map(|w| w.split(|c: char| !c.is_alphanumeric()).next().unwrap_or(""))
        .unwrap_or("")
}

fn short(v: &Value) -> String {
    v.to_string().chars().take(300).collect()
}

// ---------- Shopify ----------

pub struct Shopify {
    agent: ureq::Agent,
    base: String,
    client_id: String,
    secret: String,
    token: Option<String>,
    cost: CostState,
    meter: SharedMeter,
}

/// Shopify rate-limits GraphQL by query cost (a bucket that refills at `rate` points/second) and reports the
/// state in every response. We track it so a big sync slows itself down instead of being throttled.
#[derive(Default)]
struct CostState {
    available: Option<f64>,
    rate: f64,
    last_cost: f64,
}

impl CostState {
    fn note(&mut self, v: &Value) {
        let c = &v["extensions"]["cost"];
        if let Some(a) = c["throttleStatus"]["currentlyAvailable"].as_f64() {
            self.available = Some(a);
        }
        if let Some(r) = c["throttleStatus"]["restoreRate"].as_f64() {
            self.rate = r;
        }
        if let Some(l) = c["actualQueryCost"]
            .as_f64()
            .or(c["requestedQueryCost"].as_f64())
        {
            self.last_cost = l;
        }
    }
    /// Seconds to wait before a request about as expensive as the last one fits in the bucket.
    fn wait_secs(&self) -> f64 {
        match (self.available, self.rate) {
            (Some(a), r) if r > 0.0 && a < self.last_cost => ((self.last_cost - a) / r).min(10.0),
            _ => 0.0,
        }
    }
}

fn is_throttled(errors: &Value) -> bool {
    errors
        .as_array()
        .is_some_and(|a| a.iter().any(|e| e["extensions"]["code"] == "THROTTLED"))
}

pub struct ShopifyVariant {
    pub id: String,
    pub product_id: String,
    pub product_status: String,
    pub title: String,
    pub sku: Option<String>,
    pub price: Option<f64>,
    pub inventory_item_id: Option<String>,
    pub qty: i64,
    pub tracked: bool,
}

const PRODUCTS_QUERY: &str = "query Products($cursor: String) { products(first: 250, sortKey: TITLE, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id title status variants(first: 100) { pageInfo { hasNextPage endCursor } nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } } } } }";
const VARIANTS_QUERY: &str = "query ProductVariants($id: ID!, $cursor: String) { product(id: $id) { variants(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } } } }";

const LOCATIONS_QUERY: &str = "query Locations($cursor: String) { locations(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id name isActive } } }";
const ITEM_LEVELS_QUERY: &str = "query ItemLevels($id: ID!, $cursor: String) { inventoryItem(id: $id) { inventoryLevels(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { location { id } quantities(names: [\"available\"]) { name quantity } } } } }";
/// Aliased single-item lookups per request keep the computed GraphQL cost under Shopify's cap.
pub const LEVELS_BATCH: usize = 30;

/// One line of an order. No customer data anywhere in these types.
pub struct OrderLine {
    pub line_id: String,
    pub sku: Option<String>,
    pub variant_id: Option<String>,
    pub title: String,
    pub qty: i64,
    pub price: Option<f64>,
}
pub struct Order {
    pub id: String,
    pub name: Option<String>,
    pub created_at: String,
    pub updated_at: Option<String>,
    pub cancelled_at: Option<String>,
    pub status: Option<String>,
    pub total: Option<f64>,
    pub currency: Option<String>,
    pub lines: Vec<OrderLine>,
}

const ORDER_FIELDS: &str = "id name createdAt updatedAt cancelledAt displayFinancialStatus currentTotalPriceSet { shopMoney { amount currencyCode } } lineItems(first: 50) { pageInfo { hasNextPage endCursor } nodes { id title sku quantity currentQuantity variant { id } originalUnitPriceSet { shopMoney { amount } } } }";
// first: 10 orders x 50 lines keeps the computed cost (~510) under Shopify's 1000-point cap.
const ORDERS_QUERY_HEAD: &str = "query Orders($q: String!, $cursor: String) { orders(first: 10, query: $q, sortKey: UPDATED_AT, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { ";
const ORDER_LINES_QUERY: &str = "query OrderLines($id: ID!, $cursor: String) { order(id: $id) { lineItems(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id title sku quantity currentQuantity variant { id } originalUnitPriceSet { shopMoney { amount } } } } } }";

fn parse_line(n: &Value) -> OrderLine {
    OrderLine {
        line_id: n["id"].as_str().unwrap_or_default().into(),
        sku: n["sku"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(String::from),
        variant_id: n["variant"]["id"].as_str().map(String::from),
        title: n["title"]
            .as_str()
            .unwrap_or_default()
            .chars()
            .take(200)
            .collect(),
        qty: n["currentQuantity"]
            .as_i64()
            .or(n["quantity"].as_i64())
            .unwrap_or(0),
        price: n["originalUnitPriceSet"]["shopMoney"]["amount"]
            .as_str()
            .and_then(|s| s.parse().ok()),
    }
}

pub struct ShopLocation {
    pub id: String,
    pub name: String,
    pub active: bool,
}

impl Shopify {
    fn parse_order(&mut self, n: &Value) -> Result<Order, String> {
        let id = n["id"].as_str().unwrap_or_default().to_string();
        let mut lines: Vec<OrderLine> = n["lineItems"]["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .map(parse_line)
            .collect();
        let mut cursor = n["lineItems"]["pageInfo"]["hasNextPage"]
            .as_bool()
            .unwrap_or(false)
            .then(|| n["lineItems"]["pageInfo"]["endCursor"].clone());
        while let Some(c) = cursor.take() {
            let d = self.graphql(ORDER_LINES_QUERY, json!({ "id": id, "cursor": c }))?;
            let li = &d["order"]["lineItems"];
            lines.extend(li["nodes"].as_array().into_iter().flatten().map(parse_line));
            if li["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                cursor = Some(li["pageInfo"]["endCursor"].clone());
            }
        }
        Ok(Order {
            id,
            name: n["name"].as_str().map(String::from),
            created_at: n["createdAt"].as_str().unwrap_or_default().into(),
            updated_at: n["updatedAt"].as_str().map(String::from),
            cancelled_at: n["cancelledAt"].as_str().map(String::from),
            status: n["displayFinancialStatus"].as_str().map(String::from),
            total: n["currentTotalPriceSet"]["shopMoney"]["amount"]
                .as_str()
                .and_then(|s| s.parse().ok()),
            currency: n["currentTotalPriceSet"]["shopMoney"]["currencyCode"]
                .as_str()
                .map(String::from),
            lines,
        })
    }

    /// Orders updated since `since_iso`, oldest update first, streamed page by page. Needs the read_orders scope.
    pub fn orders(
        &mut self,
        since_iso: &str,
        mut sink: impl FnMut(Vec<Order>) -> Result<(), String>,
    ) -> Result<(), String> {
        let q = format!("{ORDERS_QUERY_HEAD}{ORDER_FIELDS} }} }} }}");
        let (mut cursor, filter) = (Value::Null, format!("updated_at:>='{since_iso}'"));
        loop {
            let d = self.graphql(&q, json!({ "q": filter, "cursor": cursor }))?;
            let page = &d["orders"];
            let mut out = Vec::new();
            for n in page["nodes"].as_array().into_iter().flatten() {
                out.push(self.parse_order(n)?);
            }
            sink(out)?;
            if page["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                cursor = page["pageInfo"]["endCursor"].clone();
            } else {
                return Ok(());
            }
        }
    }

    /// One order by id (webhook-driven refresh); None if Shopify does not know it.
    pub fn order(&mut self, id: &str) -> Result<Option<Order>, String> {
        let q = format!("query OrderById($id: ID!) {{ order(id: $id) {{ {ORDER_FIELDS} }} }}");
        let d = self.graphql(&q, json!({ "id": id }))?;
        if d["order"].is_null() {
            return Ok(None);
        }
        let n = d["order"].clone();
        self.parse_order(&n).map(Some)
    }

    /// The variant total Shopify reports for one inventory item (used by webhook-driven refreshes).
    pub fn item_total(&mut self, item_id: &str) -> Result<Option<i64>, String> {
        let d = self.graphql("query ItemTotal($id: ID!) { inventoryItem(id: $id) { variant { inventoryQuantity } } }", json!({ "id": item_id }))?;
        Ok(d["inventoryItem"]["variant"]["inventoryQuantity"].as_i64())
    }

    pub fn locations(&mut self) -> Result<Vec<ShopLocation>, String> {
        let (mut out, mut cursor) = (Vec::new(), Value::Null);
        loop {
            let d = self.graphql(LOCATIONS_QUERY, json!({ "cursor": cursor }))?;
            let page = &d["locations"];
            for n in page["nodes"].as_array().into_iter().flatten() {
                out.push(ShopLocation {
                    id: n["id"].as_str().unwrap_or_default().into(),
                    name: n["name"].as_str().unwrap_or_default().into(),
                    active: n["isActive"].as_bool().unwrap_or(true),
                });
            }
            if page["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                cursor = page["pageInfo"]["endCursor"].clone();
            } else {
                return Ok(out);
            }
        }
    }

    /// Per-location "available" quantities for up to LEVELS_BATCH inventory items.
    /// Items Shopify does not know come back absent; the caller decides the fallback.
    pub fn levels(
        &mut self,
        item_ids: &[String],
    ) -> Result<std::collections::HashMap<String, Vec<(String, i64)>>, String> {
        let mut out: std::collections::HashMap<String, Vec<(String, i64)>> =
            std::collections::HashMap::new();
        for chunk in item_ids.chunks(LEVELS_BATCH) {
            let vars = (0..chunk.len())
                .map(|i| format!("$v{i}: ID!"))
                .collect::<Vec<_>>()
                .join(", ");
            let fields = (0..chunk.len()).map(|i| format!("v{i}: inventoryItem(id: $v{i}) {{ id inventoryLevels(first: 10) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ location {{ id }} quantities(names: [\"available\"]) {{ name quantity }} }} }} }}")).collect::<Vec<_>>().join(" ");
            let variables: serde_json::Map<String, Value> = chunk
                .iter()
                .enumerate()
                .map(|(i, id)| (format!("v{i}"), json!(id)))
                .collect();
            let d = self.graphql(
                &format!("query Levels({vars}) {{ {fields} }}"),
                Value::Object(variables),
            )?;
            for (i, id) in chunk.iter().enumerate() {
                let item = &d[format!("v{i}")];
                if item.is_null() {
                    continue;
                }
                let mut nodes: Vec<Value> = item["inventoryLevels"]["nodes"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let mut cursor = item["inventoryLevels"]["pageInfo"]["hasNextPage"]
                    .as_bool()
                    .unwrap_or(false)
                    .then(|| item["inventoryLevels"]["pageInfo"]["endCursor"].clone());
                while let Some(c) = cursor.take() {
                    let more = self.graphql(ITEM_LEVELS_QUERY, json!({ "id": id, "cursor": c }))?;
                    let pg = &more["inventoryItem"]["inventoryLevels"];
                    nodes.extend(pg["nodes"].as_array().cloned().unwrap_or_default());
                    if pg["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                        cursor = Some(pg["pageInfo"]["endCursor"].clone());
                    }
                }
                let levels = nodes
                    .iter()
                    .filter_map(|n| {
                        let loc = n["location"]["id"].as_str()?;
                        let avail = n["quantities"]
                            .as_array()?
                            .iter()
                            .find(|q| q["name"] == "available")
                            .and_then(|q| q["quantity"].as_i64())
                            .unwrap_or(0);
                        Some((loc.to_string(), avail))
                    })
                    .collect();
                out.insert(id.clone(), levels);
            }
        }
        Ok(out)
    }

    pub fn new(base: String, client_id: String, secret: String, meter: SharedMeter) -> Self {
        Self {
            agent: agent(),
            base,
            client_id,
            secret,
            token: None,
            cost: CostState::default(),
            meter,
        }
    }

    fn token(&mut self) -> Result<String, String> {
        if let Some(t) = &self.token {
            return Ok(t.clone());
        }
        // Client-credentials exchange: authenticates this app, changes nothing in the shop.
        let body = json!({ "client_id": self.client_id, "client_secret": self.secret, "grant_type": "client_credentials" });
        let url = format!("{}/admin/oauth/access_token", self.base);
        let (s, v) = call(
            &self.agent,
            &self.meter,
            "token_exchange",
            "POST",
            &url,
            &[],
            Some(&body),
        )?;
        ledger("POST", &url, Some("token_exchange"), s);
        if s != 200 {
            return Err(format!("Shopify token exchange failed ({s})"));
        }
        let t = v["access_token"]
            .as_str()
            .ok_or("Shopify token exchange returned no access_token")?
            .to_string();
        self.token = Some(t.clone());
        Ok(t)
    }

    fn graphql(&mut self, query: &str, vars: Value) -> Result<Value, String> {
        check_graphql(query)?;
        let t = self.token()?;
        let url = format!("{}/admin/api/{SHOPIFY_API_VERSION}/graphql.json", self.base);
        let op = gql_op(query).to_string();
        let mut retrying = false;
        for attempt in 0..6u32 {
            // Wait until the cost bucket can hold a query like the last one. After a throttle, always
            // wait at least a second so incomplete cost data cannot turn into a tight retry loop.
            let pace = self.cost.wait_secs().max(if retrying { 1.0 } else { 0.0 });
            if pace > 0.0 {
                self.meter.lock().op(&op).wait_ms += (pace * 1000.0) as u64;
                std::thread::sleep(Duration::from_secs_f64(pace));
            }
            let (s, v) = call(
                &self.agent,
                &self.meter,
                &op,
                "POST",
                &url,
                &[("X-Shopify-Access-Token", &t)],
                Some(&json!({ "query": query, "variables": vars })),
            )?;
            ledger("POST", &url, Some(&op), s);
            if s != 200 {
                return Err(format!("Shopify GraphQL failed ({s})"));
            }
            self.cost.note(&v);
            if let Some(e) = v.get("errors").filter(|e| !e.is_null()) {
                // Cost throttling arrives as HTTP 200 with a THROTTLED error. Wait for the bucket to refill
                // (from the refill rate Shopify reports) and retry; fall back to exponential backoff when
                // the response carried no cost data.
                if is_throttled(e) && attempt < 5 {
                    {
                        let mut m = self.meter.lock();
                        let o = m.op(&op);
                        o.throttled += 1;
                        o.retries += 1;
                    }
                    if self.cost.rate <= 0.0 {
                        let wait = (1u64 << attempt).min(10);
                        self.meter.lock().op(&op).wait_ms += wait * 1000;
                        std::thread::sleep(Duration::from_secs(wait));
                    }
                    retrying = true;
                    continue;
                }
                return Err(format!("Shopify GraphQL errors: {}", short(e)));
            }
            return Ok(v["data"].clone());
        }
        Err("Shopify GraphQL stayed throttled after retries".into())
    }

    /// Streams active products' variants page by page (follows every cursor).
    pub fn variants(
        &mut self,
        mut sink: impl FnMut(Vec<ShopifyVariant>) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut cursor = Value::Null;
        loop {
            let data = self.graphql(PRODUCTS_QUERY, json!({ "cursor": cursor }))?;
            let page = &data["products"];
            let mut out = Vec::new();
            for p in page["nodes"].as_array().into_iter().flatten() {
                let pid = p["id"].as_str().unwrap_or_default().to_string();
                let pstatus = p["status"].as_str().unwrap_or("ACTIVE").to_string();
                let mut nodes: Vec<Value> = p["variants"]["nodes"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let mut vc = p["variants"]["pageInfo"]["hasNextPage"]
                    .as_bool()
                    .unwrap_or(false)
                    .then(|| p["variants"]["pageInfo"]["endCursor"].clone());
                while let Some(c) = vc.take() {
                    let d = self.graphql(VARIANTS_QUERY, json!({ "id": pid, "cursor": c }))?;
                    let vv = &d["product"]["variants"];
                    nodes.extend(vv["nodes"].as_array().cloned().unwrap_or_default());
                    if vv["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                        vc = Some(vv["pageInfo"]["endCursor"].clone());
                    }
                }
                for n in nodes {
                    out.push(ShopifyVariant {
                        id: n["id"].as_str().unwrap_or_default().into(),
                        product_id: pid.clone(),
                        product_status: pstatus.clone(),
                        title: n["title"].as_str().unwrap_or_default().into(),
                        sku: n["sku"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .map(String::from),
                        price: n["price"]
                            .as_str()
                            .and_then(|s| s.parse().ok())
                            .or(n["price"].as_f64()),
                        inventory_item_id: n["inventoryItem"]["id"].as_str().map(String::from),
                        qty: n["inventoryQuantity"].as_i64().unwrap_or(0),
                        tracked: n["inventoryItem"]["tracked"].as_bool().unwrap_or(false),
                    });
                }
            }
            sink(out)?;
            if page["pageInfo"]["hasNextPage"].as_bool().unwrap_or(false) {
                cursor = page["pageInfo"]["endCursor"].clone();
            } else {
                return Ok(());
            }
        }
    }
}

// ---------- Square ----------

pub struct Square {
    agent: ureq::Agent,
    base: String,
    token: String,
    meter: SharedMeter,
}

pub struct SquareVariation {
    pub id: String,
    pub item_id: String,
    pub name: String,
    pub sku: Option<String>,
}

impl Square {
    pub fn new(base: String, token: String, meter: SharedMeter) -> Self {
        Self {
            agent: agent(),
            base,
            token,
            meter,
        }
    }

    fn req(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        check_square(method, path)?;
        let auth = format!("Bearer {}", self.token);
        let url = format!("{}{path}", self.base);
        let op = match path.split('?').next().unwrap_or(path) {
            "/locations" => "locations",
            "/catalog/list" => "catalog_list",
            "/orders/search" | "/orders/batch-retrieve" => "orders",
            _ => "counts",
        };
        let (s, v) = call(
            &self.agent,
            &self.meter,
            op,
            method,
            &url,
            &[("Authorization", &auth), ("Square-Version", SQUARE_VERSION)],
            body.as_ref(),
        )?;
        ledger(method, &url, None, s);
        if s != 200 {
            let d = v["errors"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|e| e["detail"].as_str())
                        .collect::<Vec<_>>()
                        .join("; ")
                })
                .unwrap_or_default();
            return Err(format!(
                "Square {method} {} failed ({s}) {d}",
                path.split('?').next().unwrap_or(path)
            ));
        }
        Ok(v)
    }

    fn parse_order(o: &Value) -> Order {
        let money = |m: &Value| m["amount"].as_i64().map(|c| c as f64 / 100.0);
        let lines = o["line_items"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|l| OrderLine {
                line_id: l["uid"].as_str().unwrap_or_default().into(),
                sku: None,
                variant_id: l["catalog_object_id"].as_str().map(String::from),
                title: l["name"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(200)
                    .collect(),
                qty: l["quantity"]
                    .as_str()
                    .and_then(|q| q.parse::<f64>().ok())
                    .or(l["quantity"].as_f64())
                    .unwrap_or(0.0) as i64,
                price: money(&l["base_price_money"]),
            })
            .collect();
        Order {
            id: o["id"].as_str().unwrap_or_default().into(),
            name: None,
            created_at: o["created_at"].as_str().unwrap_or_default().into(),
            updated_at: o["updated_at"].as_str().map(String::from),
            cancelled_at: (o["state"] == "CANCELED").then(|| {
                o["closed_at"]
                    .as_str()
                    .or(o["updated_at"].as_str())
                    .unwrap_or_default()
                    .to_string()
            }),
            status: o["state"].as_str().map(String::from),
            total: money(&o["total_money"]),
            currency: o["total_money"]["currency"].as_str().map(String::from),
            lines,
        }
    }

    /// Completed orders updated since `since_iso` across the given locations (read-only search).
    pub fn orders(
        &self,
        locations: &[String],
        since_iso: &str,
        mut sink: impl FnMut(Vec<Order>) -> Result<(), String>,
    ) -> Result<(), String> {
        for chunk in locations.chunks(10) {
            let mut cursor: Option<String> = None;
            loop {
                let mut body = json!({ "location_ids": chunk, "limit": 200, "query": {
                    "filter": { "state_filter": { "states": ["COMPLETED"] }, "date_time_filter": { "updated_at": { "start_at": since_iso } } },
                    "sort": { "sort_field": "UPDATED_AT", "sort_order": "ASC" } } });
                if let Some(c) = &cursor {
                    body["cursor"] = json!(c);
                }
                let v = self.req("POST", "/orders/search", Some(body))?;
                sink(
                    v["orders"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(Self::parse_order)
                        .collect(),
                )?;
                cursor = v["cursor"]
                    .as_str()
                    .filter(|c| !c.is_empty())
                    .map(String::from);
                if cursor.is_none() {
                    break;
                }
            }
        }
        Ok(())
    }

    /// Specific orders at one location (webhook-driven refresh).
    pub fn orders_by_ids(&self, location_id: &str, ids: &[String]) -> Result<Vec<Order>, String> {
        let v = self.req(
            "POST",
            "/orders/batch-retrieve",
            Some(json!({ "location_id": location_id, "order_ids": ids })),
        )?;
        Ok(v["orders"]
            .as_array()
            .into_iter()
            .flatten()
            .map(Self::parse_order)
            .collect())
    }

    /// Active locations as (id, name).
    pub fn locations(&self) -> Result<Vec<(String, String)>, String> {
        let v = self.req("GET", "/locations", None)?;
        Ok(v["locations"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|l| l["status"] == "ACTIVE")
            .filter_map(|l| {
                Some((
                    l["id"].as_str()?.to_string(),
                    l["name"].as_str().unwrap_or_default().to_string(),
                ))
            })
            .collect())
    }

    pub fn catalog(
        &self,
        mut sink: impl FnMut(Vec<SquareVariation>) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut cursor: Option<String> = None;
        loop {
            let path = match &cursor {
                Some(c) => format!("/catalog/list?types=ITEM&limit=1000&cursor={}", enc(c)),
                None => "/catalog/list?types=ITEM&limit=1000".into(),
            };
            let v = self.req("GET", &path, None)?;
            let mut out = Vec::new();
            for o in v["objects"].as_array().into_iter().flatten() {
                if o["type"] != "ITEM" || o["is_deleted"].as_bool().unwrap_or(false) {
                    continue;
                }
                let item_name = o["item_data"]["name"].as_str().unwrap_or("Untitled item");
                for var in o["item_data"]["variations"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    if var["is_deleted"].as_bool().unwrap_or(false) {
                        continue;
                    }
                    out.push(SquareVariation {
                        id: var["id"].as_str().unwrap_or_default().into(),
                        item_id: o["id"].as_str().unwrap_or_default().into(),
                        name: var["item_variation_data"]["name"]
                            .as_str()
                            .unwrap_or(item_name)
                            .into(),
                        sku: var["item_variation_data"]["sku"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .map(String::from),
                    });
                }
            }
            sink(out)?;
            cursor = v["cursor"]
                .as_str()
                .filter(|c| !c.is_empty())
                .map(String::from);
            if cursor.is_none() {
                return Ok(());
            }
        }
    }

    /// (variation id, location id, in-stock quantity) for up to 100 variations at a time.
    pub fn counts(
        &self,
        locations: &[String],
        ids: &[String],
    ) -> Result<Vec<(String, String, i64)>, String> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut body = json!({ "location_ids": locations, "catalog_object_ids": ids, "states": ["IN_STOCK"] });
            if let Some(c) = &cursor {
                body["cursor"] = json!(c);
            }
            let v = self.req("POST", "/inventory/counts/batch-retrieve", Some(body))?;
            for c in v["counts"].as_array().into_iter().flatten() {
                if c["state"].as_str().is_some_and(|s| s != "IN_STOCK") {
                    continue;
                }
                let q = c["quantity"]
                    .as_str()
                    .and_then(|q| q.parse::<f64>().ok())
                    .or(c["quantity"].as_f64());
                if let (Some(q), Some(id), Some(loc)) = (
                    q,
                    c["catalog_object_id"].as_str(),
                    c["location_id"].as_str(),
                ) {
                    out.push((id.into(), loc.into(), q as i64));
                }
            }
            cursor = v["cursor"]
                .as_str()
                .filter(|c| !c.is_empty())
                .map(String::from);
            if cursor.is_none() {
                return Ok(out);
            }
        }
    }
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn graphql_mutations_rejected() {
        assert!(check_graphql("query Q { shop { name } }").is_ok());
        assert!(
            check_graphql("mutation { productDelete(input:{id:\"x\"}) { deletedProductId } }")
                .is_err()
        );
        assert!(check_graphql("MUTATION{x}").is_err());
        assert!(check_graphql("subscription { x }").is_err());
    }
    #[test]
    fn square_allowlist() {
        assert!(check_square("GET", "/locations").is_ok());
        assert!(check_square("GET", "/catalog/list?types=ITEM").is_ok());
        assert!(check_square("POST", "/inventory/counts/batch-retrieve").is_ok());
        assert!(
            check_square("POST", "/orders/search").is_ok()
                && check_square("POST", "/orders/batch-retrieve").is_ok()
        );
        for (m, p) in [
            ("POST", "/orders"),
            ("POST", "/orders/calculate"),
            ("PUT", "/orders/X"),
            ("POST", "/catalog/upsert"),
            ("POST", "/inventory/changes/batch-create"),
            ("DELETE", "/catalog/object/X"),
            ("PUT", "/locations"),
            ("POST", "/orders"),
            ("GET", "/payments"),
        ] {
            assert!(check_square(m, p).is_err(), "{m} {p}");
        }
    }
    #[test]
    fn cost_pacing() {
        let mut c = CostState::default();
        assert_eq!(c.wait_secs(), 0.0, "no data yet: no wait");
        c.note(&json!({ "extensions": { "cost": { "actualQueryCost": 300, "throttleStatus": { "currentlyAvailable": 100, "restoreRate": 50 } } } }));
        assert!((c.wait_secs() - 4.0).abs() < 1e-9, "(300-100)/50 s");
        c.note(&json!({ "extensions": { "cost": { "actualQueryCost": 300, "throttleStatus": { "currentlyAvailable": 900, "restoreRate": 50 } } } }));
        assert_eq!(c.wait_secs(), 0.0, "bucket has room");
        assert!(is_throttled(
            &json!([{ "extensions": { "code": "THROTTLED" }, "message": "Throttled" }])
        ));
        assert!(!is_throttled(&json!([{ "message": "other" }])));
    }
    #[test]
    fn shop_domain() {
        assert!(valid_shop_domain("my-shop.myshopify.com"));
        for d in [
            "evil.com",
            "a.myshopify.com.evil.com",
            ".myshopify.com",
            "My.myshopify.com",
            "a/b.myshopify.com",
            "http://x.myshopify.com",
        ] {
            assert!(!valid_shop_domain(d), "{d}");
        }
    }
}
