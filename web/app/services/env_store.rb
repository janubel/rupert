# frozen_string_literal: true

# Reads configuration with DB settings overriding the process environment.
# Settings are editable from the GUI/API (Settings page) so credentials and
# knobs can be imported/exported as .env text without a redeploy.
module EnvStore
  # Keys that the GUI may manage. Boot-time keys (SHOPIFY_API_KEY, SECRET,
  # RAILS_MASTER_KEY, DATABASE_URL...) are set by the droplet env instead.
  MANAGED_KEYS = %w[
    SHOPIFY_CLIENT_ID
    SHOPIFY_CLIENT_SECRET
    SHOPIFY_SHOP_DOMAIN
    SHOPIFY_LOCATION_ID
    SQUARE_APPLICATION_ID
    SQUARE_ACCESS_TOKEN
    SQUARE_ENVIRONMENT
    SQUARE_LOCATION_ID
    SQUARE_SANDBOX_APPLICATION_ID
    SQUARE_SANDBOX_ACCESS_TOKEN
    AUTHORIZE_NET_LOGIN_ID
    AUTHORIZE_NET_TRANSACTION_KEY
    AUTHORIZE_NET_CLIENT_KEY
    AUTHORIZE_NET_SANDBOX
    GOOGLE_PAY_MERCHANT_ID
    GOOGLE_PAY_MERCHANT_NAME
    APPLE_PAY_MERCHANT_ID
    APPLE_PAY_DISPLAY_NAME
    APPLE_PAY_IDENTITY_CERT
    APPLE_PAY_IDENTITY_KEY
    SYNC_MINUTES
    SYNC_HISTORY_DAYS
    GOOGLE_DRIVE_CLIENT_ID
    GOOGLE_DRIVE_CLIENT_SECRET
    GOOGLE_DRIVE_REFRESH_TOKEN
    GOOGLE_DRIVE_ALLOWED_DOMAIN
    GOOGLE_DRIVE_ACCOUNT_EMAIL
    GOOGLE_DRIVE_FOLDER_ID
    GOOGLE_DRIVE_RETENTION
    GITHUB_ISSUES_REPO
    GITHUB_ISSUES_TOKEN
    GITHUB_ISSUES_MILESTONE
    GOOGLE_OAUTH_CLIENT_ID
    GOOGLE_OAUTH_CLIENT_SECRET
    FULFILLMENT_ALERT_HOURS
    FEEDBACK_READY_SENDERS
    PUSH_GUARD_MIN_APPROVALS
    PUSH_GUARD_WINDOW_MINUTES
    PUSH_FREEZE_SHOPIFY
    PUSH_FREEZE_SQUARE
  ].freeze

  PLATFORM_KEYS = MANAGED_KEYS.grep(/\A(?:GOOGLE_DRIVE|GITHUB_ISSUES)_/).freeze

  # Whole-instance backup destinations belong to the platform operator. Never
  # consult tenant rows: they may have been configured by a store administrator.
  def self.platform_fetch(key, default = nil)
    raise ArgumentError, 'Key is not a platform setting' unless PLATFORM_KEYS.include?(key)

    setting = platform_settings[key]
    setting ? setting.value : ENV.fetch(key, default)
  end

  # All platform rows, read once per request or job; platform_set clears it.
  def self.platform_settings
    Current.metadata[:platform_settings] ||= Setting.where(key: PLATFORM_KEYS, tenant_id: nil).index_by(&:key)
  end

  def self.platform_set(key, value)
    raise ArgumentError, 'Key is not a platform setting' unless PLATFORM_KEYS.include?(key)

    Current.metadata.delete(:platform_settings)
    setting = Setting.find_by(key: key, tenant_id: nil)
    if value.nil?
      setting&.destroy!
    else
      setting ||= Setting.new(key: key, tenant_id: nil)
      setting.update!(value: value.to_s)
    end
    value
  end

  # Settings (DB) win over ENV. ENV is only consulted as a global fallback
  # when no tenant is in context (platform/setup), so tenant credentials never
  # bleed across tenants.
  #
  # All managed keys are loaded once per tenant per request cycle and memoized
  # (cleared on write), so hot paths like ConnectionsGuide that read dozens of
  # keys don't issue a query each.
  def self.fetch(key, default = nil)
    setting = all_scoped[key]
    return setting.value if setting
    return ENV.fetch(key, default) if Current.tenant_id.nil?

    default
  end

  def self.scoped(key)
    Setting.find_by(key: key, tenant_id: Current.tenant_id)
  end

  def self.all_scoped
    tenant_id = Current.tenant_id
    maps = RequestStore.fetch(:env_store_all_by_tenant) { {} }
    maps.fetch(tenant_id) do
      maps[tenant_id] = Setting.where(key: MANAGED_KEYS, tenant_id: tenant_id).index_by(&:key)
    end
  end

  def self.clear_cache!
    RequestStore.fetch(:env_store_all_by_tenant) { {} }.delete(Current.tenant_id)
  end

  # Write a managed key into the tenant settings (nil removes it).
  def self.set(key, value)
    raise ArgumentError, 'Key is not managed by the settings store' unless MANAGED_KEYS.include?(key)

    if value.nil?
      scoped(key)&.destroy
      clear_cache!
    else
      setting = Setting.find_or_initialize_by(key: key, tenant_id: Current.tenant_id)
      setting.value = value.to_s
      setting.save!
      clear_cache!
    end
    value
  end

  def self.import!(text, allow_platform: false)
    parsed = parse(text)
    if !allow_platform && (parsed.keys & PLATFORM_KEYS).any?
      raise ArgumentError, 'Google Drive instance backup settings require a platform super administrator'
    end
    parsed.each do |key, value|
      next unless MANAGED_KEYS.include?(key)

      if PLATFORM_KEYS.include?(key)
        platform_set(key, value)
      else
        setting = Setting.find_or_initialize_by(key: key, tenant_id: Current.tenant_id)
        setting.value = value
        setting.save!
      end
    end
    clear_cache!
    parsed.keys & MANAGED_KEYS
  end

  def self.export
    MANAGED_KEYS.to_h { |key| [key, effective(key)] }
  end

  def self.effective(key)
    PLATFORM_KEYS.include?(key) ? platform_fetch(key, '') : fetch(key, '')
  end

  def self.settings_map
    Setting.where(tenant_id: Current.tenant_id).to_h { |setting| [setting.key, setting.value] }
  end

  def self.mask(value)
    return '' if value.blank?

    if value.length <= 8
      '••••••••'
    else
      "#{value[0, 4]}••••#{value[-4, 4]}"
    end
  end

  def self.parse(text)
    text.to_s.lines.each_with_object({}) do |line, result|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#')

      key, _, value = stripped.partition('=')
      key = key.strip
      next if key.empty?

      value = value.strip
      value = value[1..-2] if value.start_with?('"') && value.end_with?('"')
      value = value[1..-2] if value.start_with?("'") && value.end_with?("'")
      result[key] = value
    end
  end
end
