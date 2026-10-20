# frozen_string_literal: true

class WorkspacesController < AuthenticatedController
  before_action { response.headers['Cache-Control'] = 'no-store' }
  def show
    @deployment = WorkspaceDeployment.find_by!(tenant_id: Current.user.tenant_id)
  end

  def session_start
    @deployment = WorkspaceDeployment.find_by!(tenant_id: Current.user.tenant_id)
    @handoff = WorkspaceHandoff.issue!(deployment: @deployment, user: Current.user)
    render :handoff, layout: false
  rescue ActiveRecord::RecordNotFound
    redirect_to workspace_path, alert: 'Your isolated workspace is not ready yet.'
  end
end
