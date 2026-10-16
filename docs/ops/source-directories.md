# Employee and customer directory reads

The Customers and Team → Employees pages show source status, the last successful read, and a **Sync now** button. A successful read means all native pages were fetched and validated before local publication. The recurring `DirectorySyncJob` runs every 30 minutes for active workspaces with existing authorized source credentials. C-Trax uses its existing automatic-sync switch; manual reads can still run when that switch is paused. Revoking credentials, approval, or the active workspace prevents queued reads.

## Sources

- C-Trax customers: `GET /api/v1/customers?page=N&per_page=100` after a fresh C-Trax user login.
- C-Trax staff: `GET /api/v1/users?store_id=ID&page=N&per_page=100` for each accessible store. The native portal labels these employees. Matching native IDs across accessible stores are deduplicated only when their identity fields agree. C-Trax platform/support accounts explicitly flagged `is_superuser: true` are excluded from the store employee roster.
- Shopify customers: Admin GraphQL 2026-07 `customers(first:100, after:cursor, sortKey:ID)` using the existing `read_customers` access. This imports the full directory, including customers without an imported order. Fields follow the [official customers query](https://shopify.dev/docs/api/admin-graphql/2026-07/queries/customers).

The C-Trax methods follow the observed Serv 2.0 portal contract, not a claimed supported partner API. Existing client TLS, origin, byte and time limits apply. Shopify rejects repeated cursors, duplicate/invalid native IDs and more than 200 pages; it has a three-minute read budget between requests. Failed or incomplete reads retain the previous directory and successful read count. The source does not offer a transactional remote snapshot; concurrent changes may require retrying.

Customers use tenant/source/native-ID identity. C-Trax IDs include the API host. Existing Shopify order-linked customer IDs are reused, so orders keep their associations. Contact details never merge distinct people or channels. Full directory profiles take precedence over older partial order payloads. Square's existing customer records remain available; this new scheduled directory connector covers C-Trax and Shopify. SwipeSimple/Authorize.net/NAB reporting snapshots do not establish a complete stable customer or employee directory.

Only name, email, phone and native identity are copied. No C-Trax date of birth, medical/license identifier, notes, permissions, roles or credentials are saved as directory data. C-Trax staff are mirrored as HR records with `unspecified` employment type and no inferred hire date, pay rate, or Rupert login. Existing employment status, employment terms, payroll and login links are preserved on repeat reads. A staff account removed from the source is marked source-inactive; it is not terminated or deleted in HR. Confirm the imported staff roster and employment details in Rupert before payroll use.

Access requires customer-write or HR-write permission respectively, plus sync-write. Source reads never mutate Shopify, Square or C-Trax. Safe failure messages and counts are stored in tenant-scoped `DirectorySyncState`; private contacts and source payloads do not belong in Git or job arguments.
