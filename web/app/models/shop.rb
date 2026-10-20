# frozen_string_literal: true

class Shop < ActiveRecord::Base
  include ShopifyApp::ShopSessionStorage

  # The offline Admin API token is a credential; keep it encrypted at rest like
  # every other secret in the database. Rows written before 2026-10-20 are
  # plaintext and still readable (support_unencrypted_data); run
  # `bin/rails ops:encrypt_shop_tokens` once to re-encrypt them.
  encrypts :shopify_token, :refresh_token

  def api_version
    ShopifyApp.configuration.api_version
  end
end
