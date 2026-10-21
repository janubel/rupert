# frozen_string_literal: true

class ApplicationController < ActionController::Base
  layout :workspace_layout
  before_action :reject_preview_mutation
  before_action :enforce_workspace_hostname
  before_action :set_current_context
  before_action :require_login
  before_action :enforce_instance_support_access
  before_action :enforce_workspace_location
  before_action :enforce_customer_support_access
  before_action :load_last_sync
  before_action :restrict_employee_workspace

  private

  # A preview flag must never fall through to a real write, even for a linked admin.
  def reject_preview_mutation
    head :forbidden if params[:preview].to_s == '1' && !request.get? && !request.head?
  end

  # Deny unlisted modules even if a new controller omits its permission check.
  def restrict_employee_workspace
    return unless Current.user&.employee?
    response.headers['Cache-Control'] = 'no-store'
    if controller_path == 'home' && action_name == 'index'
      return redirect_to ctrax_pos_path
    end

    allowed = case controller_path
    when 'learning'
      %w[index show complete preferences welcome onboard].include?(action_name)
    when 'sessions', 'oauth', 'employee_app', 'employee_workspace', 'employee_preview', 'customer_displays'
      true
    when 'employee_access'
      %w[edit update].include?(action_name)
    when 'projects/tasks'
      %w[index update transition move].include?(action_name)
    when 'projects/guides'
      action_name == 'show'
    when 'receipts'
      %w[index new create show edit update download submit reopen].include?(action_name)
    when 'people/timesheets'
      %w[index show new create edit update destroy submit reopen import_shifts add_entry update_entry remove_entry].include?(action_name) ||
        (%w[approve reject].include?(action_name) && People::TimesheetPolicy.assigned_demos(Current.user).where(id: params[:id]).exists?)
    when 'people/punch_history', 'people/time_keeping'
      action_name == 'index'
    when 'people/square_timesheets', 'people/ctrax_timesheets'
      %w[index show].include?(action_name)
    when 'time_clock'
      %w[index clock_in clock_out request_correction].include?(action_name)
    when 'point_of_sale', 'ctrax_pos'
      %w[index quote].include?(action_name)
    when 'pos_displays', 'pos_checkouts'
      true
    else
      false
    end
    return if allowed

    response.headers['Cache-Control'] = 'no-store'
    if request.format.html?
      redirect_to employee_app_path, alert: 'Your account can use POS, your own time records and assigned tasks.'
    else
      head :forbidden
    end
  end

  # A fixed, permission-checked landing page keeps personal defaults separate from roles.
  def sign_in_landing_path(user)
    return workspace_path if !WorkspaceNode.isolated? && WorkspaceDeployment.exists?(tenant_id: user.tenant_id)
    return employee_app_path if user.employee?
    return books_check_path if user.dashboard_config_hash['start_page'] == 'bookkeeping' && user.can?('reports.read')

    return platform_path if user.super_admin?

    root_path
  end

  def workspace_layout
    Current.user&.employee? ? 'employee' : 'application'
  end

  def enforce_workspace_hostname
    return unless WorkspaceNode.isolated?
    head :misdirected_request unless request.host == ENV['RUPERT_INSTANCE_HOSTNAME']
  end

  def enforce_workspace_location
    return unless Current.user && !WorkspaceNode.isolated? && WorkspaceDeployment.exists?(tenant_id: Current.user.tenant_id)
    return if %w[workspaces billing support_access sessions oauth instance_sessions].include?(controller_path)
    redirect_to workspace_path
  end

  def enforce_instance_support_access
    return unless WorkspaceNode.isolated? && session[:auth_method] == 'instance_support'
    return if controller_path == 'sessions' && action_name == 'destroy'
    allowed = request.get? && CustomerSupportAccess::READ_CONTROLLERS.include?(controller_path)
    begin
      allowed &&= WorkspaceNode.check_support(session[:instance_support_grant_id], session[:instance_support_user_id], "#{controller_path}##{action_name}")['active'] == true
    rescue RupertBilling::Error
      allowed = false
    end
    render plain: 'Customer support permission is missing, expired or revoked.', status: :forbidden unless allowed
  end

  def enforce_customer_support_access
    actor = Current.user
    tenant = Current.tenant
    return unless actor&.super_admin? && tenant && actor.tenant_id != tenant.id
    return if (controller_path == 'platform' && action_name == 'leave_support') || (controller_path == 'sessions' && action_name == 'destroy')
    response.headers['Cache-Control'] = 'no-store'
    grant = CustomerSupportAccess.grant_for(actor: actor, tenant: tenant)
    allowed = grant && request.get? && CustomerSupportAccess::READ_CONTROLLERS.include?(controller_path)
    CustomerSupportAccess.record!(actor: actor, tenant: tenant, grant: grant,
      action: allowed ? 'viewed' : 'denied', resource: "#{controller_path}##{action_name}")
    unless allowed
      render html: view_context.safe_join([
        view_context.content_tag(:p, 'Customer permission is required. Support grants allow selected read-only screens only.'),
        view_context.button_to('Leave support session', leave_platform_support_path, method: :delete)
      ]), status: :forbidden
    end
  end

  # Bind every role to its authenticated credentials. Legacy administrator cookies
  # must not outlive an account-link correction or password reset.
  def start_browser_session(user, method:, google_email: nil, google_identity: nil)
    reset_session
    session[:user_id] = user.id
    session[:auth_method] = method
    session[:authentication_fingerprint] = Digest::SHA256.hexdigest(user.password_digest)
    if method == 'google'
      session[:google_login_email] = google_email
      session[:google_login_identity_id] = google_identity.id if google_identity
    end
  end

  def valid_browser_session?(user)
    return false unless session[:authentication_fingerprint] == Digest::SHA256.hexdigest(user.password_digest)
    return true unless session[:auth_method] == 'google'

    email = session[:google_login_email]
    if session[:google_login_identity_id]
      GoogleLoginIdentity.exists?(id: session[:google_login_identity_id], email: email, user_id: user.id)
    else
      email.present? && email == user.email
    end
  end

  def set_current_context
    Current.user = session[:user_id] ? User.find_by(id: session[:user_id]) : nil
    if Current.user && !valid_browser_session?(Current.user)
      reset_session
      Current.user = nil
    end

    if WorkspaceNode.isolated?
      Current.tenant = Tenant.find_by(id: ENV['RUPERT_TENANT_ID'])
      if Current.user && Current.user.tenant_id != Current.tenant&.id
        reset_session
        Current.user = nil
      end
    elsif Current.user&.super_admin?
      # Super admins are platform-wide and may scope to any store via its
      # subdomain; fall back to their own tenant when the host has no matching
      # subdomain so tenant-scoped data (syncs, inventory, etc.) isn't hidden.
      Current.tenant = Tenant.find_by(id: session[:support_tenant_id]) || Tenant.find_by(subdomain: request.subdomain) || Current.user.tenant
    else
      Current.tenant = Current.user&.tenant
      Current.tenant ||= Tenant.find_by(subdomain: request.subdomain) if Current.user.nil?
    end
  end

  def require_login
    if Current.user && !Current.user.active?
      session.delete(:user_id)
      Current.user = nil
      return redirect_to(login_path, alert: 'This account has been deactivated. Contact an admin.')
    end
    if Current.user && (Current.user.tenant&.status != 'active' || Current.tenant&.status != 'active')
      session.delete(:user_id)
      Current.user = nil
      return render(plain: 'This workspace is inactive. Contact the platform administrator.', status: :forbidden)
    end
    return redirect_to(setup_path) if Current.user.nil? && !Tenant.exists?

    redirect_to(login_path, alert: 'Please sign in') unless Current.user
  end

  def load_last_sync
    @last_sync = Current.user&.active? && Current.user.can?('sync.read') ? SyncRun.order(startedAt: :desc).first : nil
  end
end
