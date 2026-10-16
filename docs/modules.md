# Rupert ERP — module map

Rupert is a modular monolith. Each feature area ships as a set of modules that
register in `app/models/module_registry.rb`, which drives the navigation and the
permission gate. New extensions live under `app/modules/<name>/` and follow the
same pattern: a namespaced model (with `TenantScoped`), a Pundit policy in
`app/policies/`, a controller under `app/controllers/<namespace>/`, views, and a
permission pair (`<area>.read` / `<area>.write`) in `User::ROLE_PERMISSIONS`
and `User.permission_catalog`.

## Overview

| Module | Purpose |
| --- | --- |
| Dashboard | Per-user customizable widgets (key stats, per-channel revenue, attention, stock alerts, sync/reconcile history, goals). |

## Commerce

| Module | Purpose |
| --- | --- |
| Sales | Daily sales journal: hourly × location pivot plus every sale in arrival order. |
| Registers | POS cash-drawer sessions: open, settle with a cash count at end of day. |
| Customers | Unified CRM across channels (searchable, paginated, lifetime value). |
| Inventory | Products/variants mirrored from Shopify with quantities on both sides and SKU linkage. |
| Inventory counts | Manual count sheets with submit / approve / reject / reopen workflow. |
| Locations | Multi-location management and inventory levels per location. |
| Orders | Detail page per order: invoice + packing slip, line items, payments, fulfillment tracking, refunds. |
| Reconcile | SKU-level drift plan between Shopify and Square with per-SKU priority policy. |

## Marketing

The optional Marketing workspace provides group topic-search links, manual thread intake and relevance triage, existing group-code records with dated merchant evidence, versioned reply review, approved copy and manual publication/removal history. It uses separate `marketing.read`, `marketing.write`, and `marketing.review` permissions and starts disabled per workspace. See the [operator guide](ops/community-marketing.md).

The [Influencer CMS](ops/influencer-cms.md) adds prospect/relationship tracking, campaign collaborations, product-gift approval and manual shipment records, temporary merchant-code records, UTM referral links and versioned documents. Private contacts, addresses, conversations and restricted documents require `marketing.contacts`. Automatic source retrieval, code activation, product fulfillment and sales attribution remain later phases.

## Operations

| Module | Purpose |
| --- | --- |
| Reports | Sales, financial (P&L), inventory, and operations reports with date windows and CSV export. |
| Ledger | Central transaction stream across all sources, filterable by window and source. |
| Projects | Project + task tracking with status transitions. |
| Goals & KPIs | Goals with measurable progress, KPIs, and reading history. |

## Purchasing

| Module | Purpose |
| --- | --- |
| Vendors | Supplier directory with purchase-order history. |
| Purchase orders | Draft → placed → received lifecycle with partial receiving and AP tracking. |

## Finance

| Module | Purpose |
| --- | --- |
| Chart of accounts | Account tree (assets, liabilities, equity, revenue, expenses) with archive/restore. |
| Accounts | Balance sheet & P&L overview built from the chart of accounts and sales. |
| Expenses | Money-out register with categories and soft delete. |
| Payments (AP) | Vendor payments recorded against invoices/purchase orders. |

## Team / People (HR)

The People module set (`app/modules/people/`) covers the full employee lifecycle
from directory to payroll.

| Module | Purpose |
| --- | --- |
| Employees | HR records: contact, employment type, status (active / on leave / terminated / rehire), department & position, emergency contact. |
| Departments | Org chart: name, code, manager, headcount. |
| Positions | Job titles and pay grades, optionally tied to a department. |
| Timesheets | Weekly hours per employee: draft → submitted → approved/rejected/reopened, with per-day entries (regular / overtime / PTO). |
| Leave & PTO | Time-off requests (vacation / sick / personal / unpaid) with approve/deny/cancel and annual balance tracking. |
| Payroll | Pay runs built from approved timesheets and current pay rates (hourly + salary), finalize → paid, with per-employee payslips (gross / deductions / net). |

## System

| Module | Purpose |
| --- | --- |
| Alerts | Low-stock flags that can be resolved or ignored. |
| Sync | Full / Shopify-only / Square-only syncs, run history, and logs. |
| SwipeSimple import | CSV export import (SwipeSimple has no public API) — idempotent feed into the canonical sales stream. |
| System health | Server load, memory, disk, database, and slow-query monitoring. |
| Connections | Human-readable guide to every service's keys: what's set, where to find each key, and how to renew it. |
| Settings | Business settings, env import/export, database backup/restore, Google Drive backup, Buzz agent, feature flags. |
| Accounts | Login accounts (who can sign in) and role assignment. |
| Permissions | Role × permission matrix with per-person overrides. |
| Warehouse | Secret vendor links with price multipliers, tiers, and a token-gated storefront. |

## Sources & sync

Rupert mirrors two platforms (Shopify, Square) plus one manual import (SwipeSimple CSV)
into a single canonical stream:

- `CatalogSyncer` / `SquareSyncer` pull products, variants, locations, and orders.
- `LedgerImporter` mirrors order money into `LedgerEntry`.
- `CanonicalOrderImporter` is the clean seam that maps platform payloads into
  `Core::Order` / `OrderLine` / `Payment` / `Customer` (idempotent upsert).
- `SwipesimpleImporter` feeds CSV exports through the same canonical seam with
  source `swipesimple`.
- `Reconciler` compares Shopify vs Square quantities per SKU; `AlertGenerator`
  flags low stock.

## Adding a new module

1. Models in `app/modules/<name>/` (include `TenantScoped`, use `AASM` for
   state machines, `Discard::Model` for soft deletes).
2. Migration for the table(s) — `tenant_id` NOT NULL, bigint ids, tenant indexes.
3. Pundit policy in `app/policies/<name>/` (or `ModulePolicy` for page-only gates).
4. Controller in `app/controllers/<name>/`, extending `AuthenticatedController`,
   authorizing each action.
5. Views under `app/views/<name>/` (Oatmeal/Tailwind classes: `card`, `stat`,
   `pill-*`, `btn-*`, `input`, `select`, `td`, `th`).
6. Permissions: add `<name>.read` / `<name>.write` to `ModulePolicy`,
   `User::ROLE_PERMISSIONS`, and `User.permission_catalog`.
7. Register the module (nav + area) in `ModuleRegistry`.
8. Routes under the matching namespace; add an integration test under
   `test/integration/`.
