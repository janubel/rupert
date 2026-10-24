# frozen_string_literal: true

class WorkspacesController < AuthenticatedController
  before_action { response.headers['Cache-Control'] = 'no-store' }
  def show
    @deployment = WorkspaceDeployment.find_by!(tenant_id: Current.user.tenant_id)
  end

  def session_start
    @deployment = WorkspaceDeployment.find_by!(tenant_id: Current.user.tenant_id)
    @handoff = WorkspaceHandoff.issue!(deployment: @deployment, user: Current.user)
    # The iPhone app posts the one-time handoff to the instance itself and moves its tabs there.
    if hotwire_native_app?
      return redirect_to(NativeSignIn.workspace_url(origin: @deployment.origin, handoff: @handoff, control: request.base_url),
        allow_other_host: true)
    end
    render :handoff, layout: false
  rescue ActiveRecord::RecordNotFound
    redirect_to workspace_path, alert: 'Your isolated workspace is not ready yet.'
  end
end
