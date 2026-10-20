# frozen_string_literal: true

class WorkspaceProvisioning
  FAILURE_CODES = %w[image_unavailable quota_exceeded create_failed bootstrap_failed health_failed routing_failed lease_expired].freeze
  PHASES = %w[queued creating bootstrapping checking routing complete failed].freeze
  def self.claim
    raise ArgumentError, 'Workspace provisioning is disabled.' unless WorkspaceNode.provisioning?
    # Claim with a conditional first write; duplicate pollers never own one lease.
    row = WorkspaceDeployment.where(status: 'requested').order(:id).first
    return unless row
    secret = SecureRandom.hex(32)
    updated = WorkspaceDeployment.where(id: row.id, status: 'requested').update_all(status: 'provisioning', phase: 'creating',
      attempts: row.attempts + 1, lease_digest: Digest::SHA256.hexdigest(secret), lease_expires_at: 30.minutes.from_now, updated_at: Time.current)
    return unless updated == 1
    row.reload
    identity = row.owner.google_login_identities.find_by!(email: row.owner.email)
    { 'id' => row.id, 'instance_id' => row.instance_id, 'instance_name' => row.instance_name,
      'hostname' => row.hostname, 'port' => row.port, 'tenant_id' => row.tenant_id,
      'workspace_name' => row.tenant.name, 'subdomain' => row.tenant.subdomain, 'owner_email' => row.owner.email, 'owner_name' => row.owner.display_name,
      'google_subject' => identity.google_subject, 'instance_secret' => row.instance_secret, 'lease' => secret }
  end

  def self.update!(id:, lease:, phase:, failure_code: nil)
    raise ArgumentError unless PHASES.include?(phase)
    row = WorkspaceDeployment.find(id)
    valid = row.lease_digest.present? && ActiveSupport::SecurityUtils.secure_compare(row.lease_digest, Digest::SHA256.hexdigest(lease.to_s))
    raise ActiveRecord::RecordNotFound unless valid && row.status == 'provisioning' && row.lease_expires_at > Time.current
    if failure_code.present?
      raise ArgumentError unless FAILURE_CODES.include?(failure_code)
      changes = { status: 'failed', phase: 'failed', failure_code: failure_code, lease_digest: nil, lease_expires_at: nil }
    elsif phase == 'complete'
      changes = { status: 'ready', phase: phase, ready_at: Time.current, lease_digest: nil, lease_expires_at: nil }
    else
      changes = { phase: phase, lease_expires_at: 30.minutes.from_now }
    end
    count = WorkspaceDeployment.where(id: row.id, status: 'provisioning', lease_digest: row.lease_digest).where('lease_expires_at > ?', Time.current).update_all(changes.merge(updated_at: Time.current))
    raise ActiveRecord::RecordNotFound unless count == 1
    row.reload
  end
end
