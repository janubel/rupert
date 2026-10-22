# frozen_string_literal: true

require 'digest'

# Named forms for the existing tenant settings store. Never returns saved secrets.
class ConnectionCredentials
  Error = Class.new(ArgumentError)
  FIELDS = {
    'shopify' => [
      ['SHOPIFY_CLIENT_ID', 'Client ID', true], ['SHOPIFY_CLIENT_SECRET', 'Client secret', true],
      ['SHOPIFY_SHOP_DOMAIN', 'Store domain', false], ['SHOPIFY_LOCATION_ID', 'Primary location (optional)', false]
    ],
    'square' => [
      ['SQUARE_APPLICATION_ID', 'Application ID (optional)', true], ['SQUARE_ACCESS_TOKEN', 'Access token', true],
      ['SQUARE_ENVIRONMENT', 'Environment (defaults to production)', false], ['SQUARE_LOCATION_ID', 'Location (optional)', false]
    ],
    'authorize_net' => [
      ['AUTHORIZE_NET_LOGIN_ID', 'API Login ID', true], ['AUTHORIZE_NET_TRANSACTION_KEY', 'Transaction Key', true],
      ['AUTHORIZE_NET_CLIENT_KEY', 'Public client key', true], ['AUTHORIZE_NET_SANDBOX', 'Sandbox checkout', false]
    ],
    'google_sign_in' => [
      ['GOOGLE_OAUTH_CLIENT_ID', 'Client ID', true], ['GOOGLE_OAUTH_CLIENT_SECRET', 'Client secret', true]
    ],
    # Apple Pay is deliberately absent: its identity certificate and key are
    # multi-line PEM, which this single-line form rejects. Those keys are set
    # from the Settings → Environment (.env) import instead.
    'google_pay' => [
      ['GOOGLE_PAY_MERCHANT_ID', 'Merchant ID (optional in sandbox)', false],
      ['GOOGLE_PAY_MERCHANT_NAME', 'Merchant name shown on the Google Pay sheet', false]
    ]
  }.freeze
  OPTIONAL_KEYS = %w[SHOPIFY_LOCATION_ID SQUARE_APPLICATION_ID SQUARE_ENVIRONMENT SQUARE_LOCATION_ID
    AUTHORIZE_NET_SANDBOX GOOGLE_PAY_MERCHANT_ID].freeze
  CHOICES = { 'SQUARE_ENVIRONMENT' => %w[production sandbox], 'AUTHORIZE_NET_SANDBOX' => %w[true false] }.freeze

  def self.fields(service)
    FIELDS.fetch(service, []).map do |key, label, secret|
      { key: key, label: label, secret: secret, optional: OPTIONAL_KEYS.include?(key), choices: CHOICES[key] }
    end
  end

  def self.token(service, actor:)
    verifier.generate({ 'service' => service, 'tenant' => Current.tenant_id, 'actor' => actor.id, 'version' => version(service) },
      expires_in: 15.minutes, purpose: 'connection-credentials')
  end

  def self.display_fields(service)
    fields(service).map do |field|
      value = EnvStore.fetch(field[:key], '')
      field.merge(saved: value.present?, value: field[:secret] ? '' : value, unreadable: false)
    rescue ActiveRecord::Encryption::Errors::Decryption
      field.merge(saved: false, value: '', unreadable: true)
    end
  end

  def self.save!(service, input, actor:)
    raise Error, 'Choose a managed workspace connection.' unless FIELDS.key?(service)
    raise Error, 'An active workspace is required.' unless Current.tenant_id

    raw_values = input.fetch(:values, {})
    raise Error, 'Provide named credential fields.' unless raw_values.is_a?(Hash)

    values = raw_values.stringify_keys
    clear = Array(input[:clear_keys]).map(&:to_s).reject(&:blank?)
    allowed = fields(service).pluck(:key)
    raise Error, 'Unsupported credential fields.' if ((values.keys + clear) - allowed).any?
    raise Error, 'Enter text values of at most 4,096 bytes without control characters.' if values.values.any? do |value|
      !value.is_a?(String) || !value.valid_encoding? || value.bytesize > 4096 || value.match?(/[\x00-\x1f\x7f]/)
    end
    values = values.transform_values(&:strip).reject { |_key, value| value.blank? }
    raise Error, 'Choose either a replacement or removal for each field.' if (values.keys & clear).any?
    CHOICES.each do |key, choices|
      raise Error, 'Choose a supported environment.' if values.key?(key) && !choices.include?(values[key])
    end
    if values['SHOPIFY_SHOP_DOMAIN'] && !values['SHOPIFY_SHOP_DOMAIN'].match?(/\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z/)
      raise Error, 'Enter the store domain ending in .myshopify.com without a URL path.'
    end

    Setting.transaction do
      locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      raise Error, 'An active workspace is required.' if locked.zero?

      expected = { 'service' => service, 'tenant' => Current.tenant_id, 'actor' => actor.id, 'version' => version(service) }
      raise Error, 'Reload the credential form before saving.' unless input[:edit_token].is_a?(String) && input[:edit_token].bytesize <= 8192
      raise Error, 'This form expired or setup changed. Reload and review the current connection.' unless verifier.verified(input[:edit_token], purpose: 'connection-credentials') == expected
      # Do not overwrite evidence encrypted under a missing/incorrect key.
      allowed.each { |key| EnvStore.fetch(key, '') }
      clear.each { |key| EnvStore.set(key, nil) }
      values.each { |key, value| EnvStore.set(key, value) }
    end
    values.length + clear.length
  rescue ActiveRecord::Encryption::Errors::Decryption
    raise Error, 'Saved credentials cannot be read. Ask the platform operator to restore the encryption keys before editing.', cause: nil
  ensure
    EnvStore.clear_cache!
  end

  def self.version(service)
    rows = Setting.where(tenant_id: Current.tenant_id, key: fields(service).pluck(:key)).order(:key)
      .pluck(:id, :key, :updated_at).map { |id, key, time| [id, key, time&.utc&.iso8601(6)] }
    Digest::SHA256.hexdigest(rows.to_json)
  end
  private_class_method :version

  def self.verifier
    Rails.application.message_verifier('connection-credentials')
  end
  private_class_method :verifier
end
