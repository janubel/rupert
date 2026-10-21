# frozen_string_literal: true

# System health page (admin only): server resources, database metrics, query
# issues, and the background job queue at a glance.
class SystemController < AuthenticatedController
  before_action :require_system_access

  def index
    @system = Rails.cache.fetch("system/health/#{Current.tenant_id}", expires_in: 60) { SystemPresenter.new }
    @sqlite = SqliteMaintenance.report
    @ai_health = AiHealthSnapshot.build
    @ops_activity = OpsActivitySnapshot.build
    @backups = BackupStatus.layers
    render('system/index')
  end

  # Queues an on-demand provider check. Throttled so the button cannot be used
  # to hammer opencode.
  def check_ai_health
    if AiHealthCheck.latest&.checked_at.to_i > 20.seconds.ago.to_i
      redirect_to(system_path(anchor: 'ai-health'), notice: 'AI health was just checked.')
    else
      AiHealthCheckJob.perform_later('manual')
      redirect_to(system_path(anchor: 'ai-health'), notice: 'AI health check queued. Reload in a few seconds for the result.')
    end
  end

  private

  def require_system_access
    actor = User.find_by(id: Current.user&.id, active: true)
    return if actor&.super_admin? && actor.can?('system.read')

    redirect_to(root_path, alert: "You don't have permission to view system health.")
  end
end
