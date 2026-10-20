# frozen_string_literal: true

module Internal
  class WorkspaceSessionsController < ActionController::API
    before_action :authenticate_instance
    rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
    def exchange
      render json: WorkspaceHandoff.consume!(deployment: @deployment, secret: params[:code])
    end

    def support
      actor = User.find_by!(id: params[:user_id], role: 'super_admin', active: true)
      grant = CustomerSupportAccess.grant_for(actor: actor, tenant: @deployment.tenant)
      return head :forbidden unless grant && grant.id.to_s == params[:grant_id].to_s && actor.tenant&.status == 'active' && @deployment.tenant.status == 'active'
      CustomerSupportAccess.record!(actor: actor, tenant: @deployment.tenant, grant: grant, action: 'viewed', resource: params[:resource].to_s.first(120))
      render json: { active: true }
    end

    private

    def authenticate_instance
      response.headers['Cache-Control'] = 'no-store'
      return head :not_found if WorkspaceNode.isolated?
      @deployment = WorkspaceDeployment.find_by!(instance_id: params[:id], status: 'ready')
      actual = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(@deployment.instance_secret, actual)
    end
  end
end
