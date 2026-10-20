# frozen_string_literal: true

# Active Record encryption keys. In production these come from the droplet
# environment (RAILS_ENCRYPTION_*_KEY) and are required: falling back to
# well-known keys here would silently store every tenant token (Square, Shopify
# client secret, Drive refresh, Buzz keys) in a way anyone with the source can
# decrypt. Development/test use fixed keys so encrypted settings work out of
# the box locally.
# SECRET_KEY_BASE_DUMMY marks a build-time run (asset precompile in the Docker
# image) where no real keys exist and no database is touched.
if Rails.env.production? && ENV['SECRET_KEY_BASE_DUMMY'].blank?
  %w[RAILS_ENCRYPTION_PRIMARY_KEY RAILS_ENCRYPTION_DETERMINISTIC_KEY RAILS_ENCRYPTION_KEY_DERIVATION_SALT].each do |key|
    if ENV[key].blank?
      raise "Missing #{key} in the environment — set it (bin/rails db:encryption:init) or encrypted settings will be unreadable"
    end
  end
else
  ENV['RAILS_ENCRYPTION_PRIMARY_KEY'] ||= 'dev-primary-key-0123456789abcdef'
  ENV['RAILS_ENCRYPTION_DETERMINISTIC_KEY'] ||= 'dev-deterministic-key-0123456789'
  ENV['RAILS_ENCRYPTION_KEY_DERIVATION_SALT'] ||= 'dev-kdf-salt-0123456789abcdef'
end

Rails.application.config.active_record.encryption.primary_key = ENV.fetch('RAILS_ENCRYPTION_PRIMARY_KEY')
Rails.application.config.active_record.encryption.deterministic_key = ENV.fetch('RAILS_ENCRYPTION_DETERMINISTIC_KEY')
Rails.application.config.active_record.encryption.key_derivation_salt = ENV.fetch('RAILS_ENCRYPTION_KEY_DERIVATION_SALT')

# Columns that gained `encrypts` after rows already existed (shops.shopify_token,
# 2026-10-20) keep reading their plaintext values until ops:encrypt_shop_tokens
# has rewritten them. New writes are always encrypted.
Rails.application.config.active_record.encryption.support_unencrypted_data = true
