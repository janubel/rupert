# frozen_string_literal: true

class WorkspaceDeployment < ApplicationRecord
  belongs_to :tenant
  belongs_to :owner, class_name: 'User'
  has_many :workspace_handoffs, dependent: :restrict_with_exception
  encrypts :instance_secret
  validates :status, inclusion: { in: %w[requested provisioning ready failed] }
  validates :tenant_id, :instance_id, :hostname, uniqueness: true
  validates :instance_id, format: { with: /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/ }
  validates :hostname, format: { with: /\A[a-z0-9][a-z0-9.-]*[a-z0-9]\z/ }
  attr_readonly :tenant_id, :owner_id, :instance_id, :hostname

  def self.request!(tenant:, owner:)
    domain = ENV.fetch('RUPERT_WORKSPACE_BASE_DOMAIN', 'workspaces.rupertpos.com')
    raise ArgumentError, 'Configure a workspace base domain.' unless domain.match?(/\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}\z/)
    create!(tenant: tenant, owner: owner, instance_id: SecureRandom.uuid,
      hostname: "#{tenant.subdomain}.#{domain}", instance_secret: SecureRandom.hex(32))
  end

  def origin
    "https://#{hostname}"
  end

  def instance_name
    "rupert-customer-#{instance_id}"
  end

  def port
    value = 24000 + id
    raise ArgumentError, 'Provisioning port allocation exhausted.' if value >= 25000
    value
  end
end
