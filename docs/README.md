# Rupert docs

NAB / IRIS deposits, transactions and Health Center summaries: [integration, access and ongoing operation](ops/iris-reporting.md).
Expanded NAB / IRIS evidence, endpoint inventory, native exports and remaining access questions: [integration investigation](ops/iris-integration-investigation.md).

Start here to resume operator rollout: [Derrick's day-to-day readiness and pickup plan](ops/day-to-day-readiness.md). It separates usable daily review workflows from the payment and inventory gates that still block replacing the current systems.

Marketing operators: [Community thread and reply review](ops/community-marketing.md) explains topic search, manual intake, group-code evidence, reply approval and manual publication.

Influencer operators: [Influencer CMS](ops/influencer-cms.md) covers prospects, collaborations, product gifts, temporary code records, referral URLs, private contacts and versioned documents.

| Where | What |
| --- | --- |
| `index.html`, `getting-started.html`, `architecture.html`, `modules.html`, `operations.html`, `deployment.html` | The published docs site (GitHub Pages, styled by `assets/style.css`) |
| `BRANCHING.md` | Branch strategy: `main` = Rails production |
| `ops/operator-runbook.md`, `ops/backup-restore-runbook.md`, `ops/environment-reference.md`, `ops/release-process.md`, `ops/go-live-checklist.md` | Running the shop: daily checks, stuck syncs, restore drill and procedure, every variable, how to release and roll back, go-live gates |
| `audits/production-readiness.md` | 2026-10-20 production readiness audit: findings, fix status, what the owner must do |
| `ops/security-scanning.md` | Security CI (bundler-audit, Brakeman baseline) and the triage of accepted warnings |
| `modules.md` | How to add an ERP module under `web/app/modules/` |
| `plans/` | Design and migration plans (drift migration, phase plan, staffing model) |
| `audits/` | Dated inventory/SKU audits with their findings. Raw CSV/JSON output sits in `audits/data/` |
| `research/` | Background research that informed product decisions |
| `ops/` | Operator material (the Buzz agent prompt) |

Product pages: `roadmap.html`, `competitors.html`, and `sqlite-incus.html`. Edit the catalog at `web/config/product_roadmap.json`, the matrix at `docs/data/competitor-matrix.json`, or the runbook at `docs/ops/sqlite-incus.md`, then run `bin/build-product-site`. CI runs `--check` to detect drift. Matrix cells link to official source pages; "Not established" is an unknown, not an absence claim.

The current operating decision and restore/scaling guidance are in `ops/sqlite-incus.md`; cutover evidence is in `ops/sqlite-migration.md`. SER8-specific units and a host freshness watcher are under `deploy/`.

- [Dashboard source status and 30-minute reads](ops/source-sync-status.md)

## Repository continuity

- [Main / SER8 reconciliation and preserved PR work](ops/repository-reconciliation-2026-10-16.md).
- [Historical record backfills and recovery checks](ops/historical-records.md).
- [Community and influencer implementation plan (historical)](plans/community-and-influencer-marketing.md).

Preserved research: [Authorize.net API investigation](ops/authorize-net-api-investigation.md), [earlier gateway investigation](ops/authorize-net-integration-investigation.md), and [historical C-Trax investigation](ctrax-integration-research.md). Provider enablement remains separate from documentation reconciliation.
