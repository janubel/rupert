# Rupert read API v1

The first API release exposes tenant-scoped catalog, mirrored inventory and the
feature roadmap. It does not write inventory, change listings, trigger platform
syncs, process orders or send messages. Shopify and Square connectors continue
to operate independently.

## Create and rotate a token

An operator with `settings.write` opens **System → API integrations**, gives the
integration a name, selects scopes and optionally sets an expiry. The default
expiry in the form is 90 days. Copy the new token immediately: the full secret is
displayed only in the creation response. Rupert stores a SHA256 digest and a
short display hint. Put the token in a secret manager, never a browser bundle,
URL, source repository or chat message.

Create a replacement token, update the client, confirm the replacement works,
then revoke the old token on the same screen. Revocation applies to the next API
request. Deleting an owner removes their tokens. Tokens also stop authenticating when expired, when their owner is
disabled, or when their tenant is inactive. The owner's current read permissions
are checked on every request; issuing a token does not preserve removed access.

## Authentication and scopes

Use HTTPS with the `Authorization: Bearer YOUR_TOKEN` header. Browser cookies,
hostnames and query parameters cannot change the token's tenant.

| Scope | Endpoint | Owner permission |
| --- | --- | --- |
| `catalog:read` | `GET /api/v1/catalog` | `inventory.read` |
| `inventory:read` | `GET /api/v1/inventory` | `inventory.read` |
| `roadmap:read` | `GET /api/v1/roadmap` | Active owner |

The scopes `reports:read`, `timesheets:read`, `tasks:read`, `alerts:read`,
`system:read` and `tasks:write` currently gate only tools on the MCP server for AI assistants
(`POST /mcp`). See [docs/mcp.md](mcp.md) for connecting Claude, ChatGPT and
other assistants with the same tokens, the tool list and the feedback channel.

Invalid, revoked and expired tokens receive JSON `401` with a
`WWW-Authenticate: Bearer` header. Valid tokens without the required scope or
current owner permission receive JSON `403`. Invalid list parameters receive
JSON `400`. Responses use `Cache-Control: no-store`.

```sh
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" \
  'https://herbalhealers.rupertpos.com/api/v1/catalog?source=shopify&per_page=50'

curl -H "Authorization: Bearer $RUPERT_API_TOKEN" \
  'https://herbalhealers.rupertpos.com/api/v1/inventory?source=square&per_page=50'
```

## List contract

Catalog and inventory return `{ "data": [...], "meta": {...} }`. Lists are
ordered by record ID for stable ordering within an unchanged mirror. Pass
`page=1` and `per_page=50` (the defaults). `per_page` must be 1–100, and `page`
must be 1–1000. Follow `meta.next_page` until it is `null`. `meta.has_more`
indicates that additional data exists; reaching the page limit requires a
narrower inventory filter. Pagination is a live read, so a source sync between
requests can change the result set.

Catalog requires one source per request: `source=shopify` (default) or
`source=square`. Each row contains `id`, `source`, `sku`, `name`, `product_id` and
`price`. Square prices are `null` because the current Square mirror does not
store them. IDs belong to their respective source; an identical SKU does not
combine products across sources.

Inventory accepts optional `source=shopify|square` and `location_id` filters.
Each row contains `id`, `source`, `location_id`, `item_id`, `quantity`,
`available` and `updated_at`. Values are mirrored platform/location values,
not a live platform promise. Local advisory stock holds are not subtracted
from these source fields. Different Shopify and Square quantities are expected;
clients must not use this read API to infer automatic equalization.

Roadmap returns the same feature catalog used by the signed-in roadmap and
public GitHub Pages site, wrapped in `data` with `meta.api_version`.

## Remaining integration work

The separate [POS account setup guide](https://techmore.github.io/rupert/payment-integrations.html) documents encrypted KORONA/Cova credentials, selected Valmar Authorize.net/NMI credential/profile checks and vendor-access preparation. Those checks do not import business data or process payments.

The separate [reviewed CSV import guide](https://techmore.github.io/rupert/sales-imports.html) describes a prepared SwipeSimple line-item sales contract; that browser workflow is not an API endpoint.

This is a read integration foundation. Per-client rate limits, webhooks,
idempotent write contracts, OpenAPI generation, source-specific marketplace or
accounting adapters and offline synchronization remain roadmap work. Choose
those adapters against the actual target service and sandbox requirements.
