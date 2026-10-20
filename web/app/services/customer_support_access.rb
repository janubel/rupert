# frozen_string_literal: true

# This is an application authorization boundary, not operator-proof encryption.
class CustomerSupportAccess
  READ_CONTROLLERS = %w[home sales inventory customers orders reports ledger activity people/employees people/timesheets finance/reports finance/accounts].freeze
  def self.grant_for(actor:, tenant:)
    SupportAccessGrant.current.find_by(tenant_id: tenant.id, support_user_id: actor.id)
  end

  def self.record!(actor:, tenant:, grant:, action:, resource: nil)
    SupportAccessEvent.create!(actor: actor, tenant: tenant, support_access_grant: grant, action: action, resource: resource)
  end
end
