# frozen_string_literal: true

# Per-tenant feature flags, stored as Setting rows. A flag is enabled when the
# Setting value is "1" (absent = off), so new features ship disabled by default.
class FeatureFlag
  FLAGS = {
    fulfillment_workflow: 'fulfillment_workflow_enabled',
    marketing: 'marketing_enabled'
  }.freeze

  class << self
    # Read once per request or job (Current resets between them); set clears it.
    def enabled?(flag)
      key = FLAGS.fetch(flag.to_sym)
      cache = (Current.metadata[:feature_flags] ||= {})
      cache.fetch([Current.tenant_id, key]) do
        cache[[Current.tenant_id, key]] = Setting.find_by(key: key, tenant_id: Current.tenant_id)&.value == '1'
      end
    end

    def set(flag, enabled)
      key = FLAGS.fetch(flag.to_sym)
      Current.metadata.delete(:feature_flags)
      Setting.find_or_create_for(key, Current.tenant_id) do |setting|
        setting.value = enabled ? '1' : '0'
      end
    end
  end
end
