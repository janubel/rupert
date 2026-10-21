# frozen_string_literal: true

# Per-tenant business settings stored as Setting rows. Fallbacks keep the app
# working before any settings are configured.
class TenantSettings
  DEFAULTS = {
    business_name: 'Herbal Healers',
    invoice_prefix: 'INV',
    low_stock_threshold: 5,
    # Percent used only to estimate tax for sources that do not report it
    # (SwipeSimple). Blank means no estimate is shown.
    sales_tax_rate: ''
  }.freeze

  class << self
    DEFAULTS.each_key do |key|
      define_method(key) do
        value = Setting.find_by(key: "tenant_#{key}", tenant_id: Current.tenant_id)&.value
        value.presence || DEFAULTS[key]
      end
    end

    def set(key, value)
      raise ArgumentError, "unknown setting #{key}" unless DEFAULTS.key?(key.to_sym)

      Setting.find_or_create_for("tenant_#{key}", Current.tenant_id) do |setting|
        setting.value = value.to_s
      end
    end

    def low_stock_threshold_int
      low_stock_threshold.to_s.to_i
    end
  end
end
