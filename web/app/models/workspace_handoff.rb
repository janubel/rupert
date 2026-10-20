# frozen_string_literal: true

class WorkspaceHandoff < ApplicationRecord
  belongs_to :workspace_deployment
  belongs_to :user
  belongs_to :support_access_grant, optional: true
  validates :token_digest, uniqueness: true

  def self.issue!(deployment:, user:, grant: nil)
    raise ActiveRecord::RecordNotFound unless deployment.status == 'ready' && user.active? && deployment.tenant.status == 'active'
    if grant
      fresh = CustomerSupportAccess.grant_for(actor: user, tenant: deployment.tenant)
      raise ActiveRecord::RecordNotFound unless user.super_admin? && fresh&.id == grant.id
    else
      raise ActiveRecord::RecordNotFound unless user.tenant_id == deployment.tenant_id && user.admin?
    end
    secret = SecureRandom.urlsafe_base64(32)
    create!(workspace_deployment: deployment, user: user, support_access_grant: grant,
      token_digest: Digest::SHA256.hexdigest(secret), expires_at: 2.minutes.from_now)
    secret
  end

  def self.consume!(deployment:, secret:)
    raise ActiveRecord::RecordNotFound unless secret.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)
    row = find_by!(workspace_deployment: deployment, token_digest: Digest::SHA256.hexdigest(secret))
    transaction do
      changed = where(id: row.id, consumed_at: nil).where('expires_at > ?', Time.current).update_all(consumed_at: Time.current)
      raise ActiveRecord::RecordNotFound unless changed == 1 && row.user.active? && deployment.tenant.status == 'active'
      if row.support_access_grant_id
        grant = CustomerSupportAccess.grant_for(actor: row.user, tenant: deployment.tenant)
        raise ActiveRecord::RecordNotFound unless row.user.super_admin? && grant&.id == row.support_access_grant_id
        CustomerSupportAccess.record!(actor: row.user, tenant: deployment.tenant, grant: grant, action: 'viewed', resource: 'isolated_instance_session')
      else
        raise ActiveRecord::RecordNotFound unless row.user.tenant_id == deployment.tenant_id && row.user.admin?
      end
      { 'email' => row.user.email, 'name' => row.user.display_name, 'user_id' => row.user_id,
        'support_grant_id' => row.support_access_grant_id, 'workspace_id' => deployment.instance_id,
        'tenant_id' => deployment.tenant_id,
        'google_subject' => row.user.google_login_identities.find_by(email: row.user.email)&.google_subject }
    end
  end
end
