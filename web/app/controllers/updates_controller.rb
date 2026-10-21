# frozen_string_literal: true

# System → Updates (instance operators only): what build this server runs, what
# GitHub main has, what the host deployer last did, and controls to install now,
# cancel a request, retry a failed update or switch between automatic and
# manual installs. Rupert never installs code itself; see AutoUpdate.
class UpdatesController < AuthenticatedController
  before_action :require_update_access
  before_action :require_update_control, except: :show
  before_action :require_deployer, only: %i[install mode]

  def show
    @build = BuildInfo.current
    @check = UpdateChecker.latest
    @status = AutoUpdate.status
    @last_deploy = AutoUpdate.last_deploy
    @manual = AutoUpdate.manual?
    @requested_at = AutoUpdate.requested_at
    @can_control = AutoUpdate.operator?(@actor)
  end

  def check
    result = UpdateChecker.enabled? ? UpdateChecker.refresh! : nil
    redirect_to system_updates_path, notice: check_notice(result)
  end

  def install
    AutoUpdate.request_install!(actor: @actor)
    ActivityLogger.log('update_install_requested', details: "Requested from build #{BuildInfo.current.short_revision}")
    redirect_to system_updates_path, notice: 'Install requested. The updater checks that CI passed, backs up the database and restarts Rupert; this page will be unavailable for a minute or two.'
  rescue SystemCallError => e
    redirect_to system_updates_path, alert: "Couldn't hand the request to the updater (#{e.class.name.demodulize})."
  end

  def cancel
    AutoUpdate.cancel_request!
    ActivityLogger.log('update_install_cancelled')
    redirect_to system_updates_path, notice: 'Install request cancelled.'
  end

  def mode
    manual = params[:mode] == 'manual'
    AutoUpdate.manual!(manual)
    ActivityLogger.log('update_mode_changed', details: manual ? 'manual' : 'automatic')
    mode_notice = manual ? 'Updates now install only when you click Install.' : 'Updates now install automatically once CI passes.'
    redirect_to system_updates_path, notice: "#{mode_notice} The updater applies this on its next check."
  rescue SystemCallError => e
    redirect_to system_updates_path, alert: "Couldn't change the update mode (#{e.class.name.demodulize})."
  end

  private

  def check_notice(result)
    return "Couldn't reach GitHub just now. Try again in a few minutes." if result.nil?
    return "#{helpers.pluralize(result.behind_by, 'newer change')} on GitHub main." if result.available?

    'This server runs the newest code on GitHub main.'
  end

  def require_update_access
    @actor = User.find_by(id: Current.user&.id, active: true)
    return if AutoUpdate.manager?(@actor)

    redirect_to(root_path, alert: "You don't have permission to manage updates.")
  end

  def require_update_control
    return if AutoUpdate.operator?(@actor)

    redirect_to(system_updates_path, alert: "You don't have permission to change updates.")
  end

  def require_deployer
    return if AutoUpdate.installed?

    redirect_to(system_updates_path, alert: 'The updater is not installed on this server.')
  end
end
