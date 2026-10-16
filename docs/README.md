# Rupert docs

NAB / IRIS deposits, transactions and Health Center summaries: [integration, access and ongoing operation](ops/iris-reporting.md).
Expanded NAB / IRIS evidence, endpoint inventory, native exports and remaining access questions: [integration investigation](ops/iris-integration-investigation.md).

Start here to resume operator rollout: [Derrick's day-to-day readiness and pickup plan](ops/day-to-day-readiness.md). It separates usable daily review workflows from the payment and inventory gates that still block replacing the current systems.

| Where | What |
| --- | --- |
| `index.html`, `getting-started.html`, `architecture.html`, `modules.html`, `operations.html`, `deployment.html` | The published docs site (GitHub Pages, styled by `assets/style.css`) |
| `modules.md` | How to add an ERP module under `web/app/modules/` |
| `plans/` | Design and migration plans (drift migration, phase plan, staffing model) |
| `audits/` | Dated inventory/SKU audits with their findings. Raw CSV/JSON output sits in `audits/data/` |
| `research/` | Background research that informed product decisions |
| `ops/` | Operator material (the Buzz agent prompt) |

Product pages: `roadmap.html`, `competitors.html`, and `sqlite-incus.html`. Edit the catalog at `web/config/product_roadmap.json`, the matrix at `docs/data/competitor-matrix.json`, or the runbook at `docs/ops/sqlite-incus.md`, then run `bin/build-product-site`. CI runs `--check` to detect drift. Matrix cells link to official source pages; "Not established" is an unknown, not an absence claim.

The current operating decision and restore/scaling guidance are in `ops/sqlite-incus.md`; cutover evidence is in `ops/sqlite-migration.md`. SER8-specific units and a host freshness watcher are under `deploy/`.
