# frozen_string_literal: true

# System health page (admin only): server resources, database metrics, query
# issues, and the background job queue at a glance.
class SystemController < AuthenticatedController
  before_action :require_system_access

  def index
    @system = Rails.cache.fetch("system/health/#{Current.tenant_id}", expires_in: 60) { SystemPresenter.new }
    @sqlite = SqliteMaintenance.report
    render('system/index')
  end

  private

  def require_system_access
    actor = User.find_by(id: Current.user&.id, active: true)
    return if actor&.super_admin? && actor.can?('system.read')

    redirect_to(root_path, alert: "You don't have permission to view system health.")
  end
end
