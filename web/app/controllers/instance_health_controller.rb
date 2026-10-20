# frozen_string_literal: true

class InstanceHealthController < ActionController::API
  def show
    response.headers['Cache-Control'] = 'no-store'
    secret = ENV['RUPERT_INSTANCE_SECRET'].to_s
    actual = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
    return head :unauthorized unless WorkspaceNode.isolated? && secret.length >= 32 && ActiveSupport::SecurityUtils.secure_compare(secret, actual)
    return head :misdirected_request unless request.host == ENV['RUPERT_INSTANCE_HOSTNAME']
    tenant_id = ENV['RUPERT_TENANT_ID']
    ready = ApplicationRecord.connection.adapter_name == 'SQLite' && Tenant.count == 1 && Tenant.exists?(id: tenant_id, status: 'active') && !User.where.not(tenant_id: tenant_id).exists?
    render json: { ready: ready, instance_id: ENV['RUPERT_WORKSPACE_ID'], tenant_id: tenant_id,
      revision: BuildInfo.current.revision }, status: ready ? :ok : :service_unavailable
  end
end
