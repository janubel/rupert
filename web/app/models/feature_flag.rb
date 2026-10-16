# frozen_string_literal: true

# Per-tenant feature flags, stored as Setting rows. A flag is enabled when the
# Setting value is "1" (absent = off), so new features ship disabled by default.
class FeatureFlag
  FLAGS = {
    fulfillment_workflow: 'fulfillment_workflow_enabled',
    marketing: 'marketing_enabled'
  }.freeze

  class << self
    def enabled?(flag)
      key = FLAGS.fetch(flag.to_sym)
      Setting.find_by(key: key, tenant_id: Current.tenant_id)&.value == '1'
    end

    def set(flag, enabled)
      key = FLAGS.fetch(flag.to_sym)
      Setting.find_or_create_for(key, Current.tenant_id) do |setting|
        setting.value = enabled ? '1' : '0'
      end
    end
  end
end
