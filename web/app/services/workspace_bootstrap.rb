# frozen_string_literal: true

class WorkspaceBootstrap
  def self.call(data)
    raise ArgumentError, 'Workspace mode and SQLite are required.' unless WorkspaceNode.isolated? && ApplicationRecord.connection.adapter_name == 'SQLite'
    tenant_id = ENV.fetch('RUPERT_TENANT_ID')
    raise ArgumentError, 'Wrong workspace identity.' unless data.fetch('tenant_id') == tenant_id && data.fetch('instance_id') == ENV.fetch('RUPERT_WORKSPACE_ID')
    raise ArgumentError, 'Missing verified owner.' unless data['google_subject'].present? && data['owner_email'].to_s.match?(URI::MailTo::EMAIL_REGEXP)
    Tenant.transaction do
      raise ArgumentError, 'Refusing a database containing another tenant.' if Tenant.where.not(id: tenant_id).exists?
      tenant = Tenant.find_or_initialize_by(id: tenant_id)
      tenant.assign_attributes(name: data.fetch('workspace_name'), subdomain: data.fetch('subdomain'), status: 'active')
      tenant.save!
      user = User.find_or_initialize_by(email: data.fetch('owner_email'))
      raise ArgumentError, 'Conflicting owner account.' if user.persisted? && (user.tenant_id != tenant.id || !user.admin?)
      user.assign_attributes(tenant: tenant, name: data.fetch('owner_name'), role: 'admin', active: true)
      user.password = SecureRandom.hex(32) if user.new_record?
      user.save!
      identity = GoogleLoginIdentity.find_or_initialize_by(email: user.email)
      raise ArgumentError, 'Conflicting owner identity.' if identity.persisted? && identity.user_id != user.id
      identity.user = user
      identity.save!
      identity.verify_subject!(data.fetch('google_subject'))
      Current.set(tenant: tenant) { Finance::ChartOfAccounts.seed! }
    end
    true
  end
end
