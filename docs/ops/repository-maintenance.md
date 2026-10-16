# Repository maintenance

The Rails application in `web/` is the active web service. `mobile/` is the
employee client; `legacy/` is retained reference material. The generated
product site in `docs/` is checked against `web/config/product_roadmap.json`.

## Validation

From a clean development or CI checkout:

```sh
python3 bin/build-product-site --check
python3 bin/check-doc-links
node --test web/test/javascript/*_test.mjs
npm ci --prefix mobile
npm run check --prefix mobile
git diff --check
```

The mobile check includes SDK compatibility, TypeScript, employee boundaries,
and the recorded security backports. A registry audit alone still reports
the patched upstream versions; `audit:security` verifies the backports before
accepting those documented exceptions.

Run Rails checks from `web/` in an isolated checkout with a dedicated test
database. No production environment file is needed:

```sh
export RAILS_ENV=test RUPERT_DB_ADAPTER=sqlite3
export SHOPIFY_API_KEY=test-api-key SHOPIFY_API_SECRET=test-secret-key
export HOST=app-host-name.io
bundle install
bundle exec rubocop -c rubocop.yml
bin/rails db:prepare
bin/rails tailwindcss:build
bin/rails assets:precompile
bin/rails test
```

CI repeats the Rails suite with PostgreSQL and SQLite. Browser tests are
discovered by filename rather than an explicit list. New browser tests use
`web/test/javascript/*_test.mjs`. Native export verification remains in the
Employee mobile workflow; signing and distributing a binary are separate.

## Git and deployment

On October 16, 2026, the `0cd3be6` running release had 259 commits beyond
`main`, while `main` had 11 commits absent from that release. This is a
stacked release history, not an interchangeable set of checkouts. Pending
feature branches and PRs must be reviewed in dependency order; deleting
branches or replacing production with `main` would lose deployed features.

Before editing, record the actual production revision and start from that
revision when preparing a release. Keep each change committed and pushed.
Use a PR against its immediate base so the diff contains the intended work.
Keep other active chats' uncommitted changes in their own checkouts.

Before promotion, require a clean live checkout and compare its revision
to the tested base under the deployment lock. If another release advanced
production, incorporate that release and retest the combined candidate.
Retain prior source and deployment receipts. A Git push does not deploy.

## Branding

The approved face remains 40px in headers and 96px on the login card.
`shared/rupert_face` selects responsive 80px/192px PNGs with the 512px
master as a fallback. The small files reduce normal header downloads from
273,008 bytes to 12,443 bytes without changing the display size.
Keep explicit dimensions, empty decorative alt text beside the brand name,
and accessible labels on the surrounding links.

Generated assets, local databases, `.env` files, logs, dependency directories,
and private source exports stay ignored. Keep tracked `.keep` placeholders
and operational history. `git fsck` may report unreachable objects retained
from prior work; that does not indicate corruption or justify pruning them.
