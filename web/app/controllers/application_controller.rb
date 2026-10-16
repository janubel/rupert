# frozen_string_literal: true

class ApplicationController < ActionController::Base
  layout :workspace_layout
  before_action :reject_preview_mutation
  before_action :set_current_context
  before_action :load_last_sync
  before_action :require_login
  before_action :restrict_employee_workspace

  private

  # A preview flag must never fall through to a real write, even for a linked admin.
  def reject_preview_mutation
    head :forbidden if params[:preview].to_s == '1' && !request.get? && !request.head?
  end

  # Deny unlisted modules even if a new controller omits its permission check.
  def restrict_employee_workspace
    return unless Current.user&.employee?
    if controller_path == 'home' && action_name == 'index'
      return redirect_to ctrax_pos_path
    end

    allowed = case controller_path
    when 'sessions', 'oauth', 'employee_app', 'employee_workspace', 'employee_preview', 'customer_displays'
      true
    when 'employee_access'
      %w[edit update].include?(action_name)
    when 'people/timesheets'
      %w[index show new create edit update destroy submit reopen import_shifts add_entry update_entry remove_entry].include?(action_name)
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
      redirect_to employee_app_path, alert: 'Your account can use POS and your own time records.'
    else
      head :forbidden
    end
  end

  def workspace_layout
    Current.user&.employee? ? 'employee' : 'application'
  end

  def set_current_context
    Current.user = session[:user_id] ? User.find_by(id: session[:user_id]) : nil

    if Current.user&.super_admin?
      # Super admins are platform-wide and may scope to any store via its
      # subdomain; fall back to their own tenant when the host has no matching
      # subdomain so tenant-scoped data (syncs, inventory, etc.) isn't hidden.
      Current.tenant = Tenant.find_by(subdomain: request.subdomain) || Current.user.tenant
    else
      Current.tenant = Current.user&.tenant
      Current.tenant ||= Tenant.find_by(subdomain: request.subdomain) if Current.user.nil?
    end
  end

  def require_login
    if Current.user&.employee? && session[:employee_password_fingerprint] != Digest::SHA256.hexdigest(Current.user.password_digest)
      reset_session
      Current.user = nil
    end
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
