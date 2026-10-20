# frozen_string_literal: true

# The one place the Shopify Admin API version is pinned. ShopifyClient (sync
# engine), the shopify_app initializer (OAuth/webhooks) and shopify.app.toml
# (webhook subscriptions) must agree; test/services/shopify_client_test.rb
# checks the TOML against this constant. Upgrade procedure: docs/ops/operator-runbook.md.
SHOPIFY_ADMIN_API_VERSION = '2026-07'
