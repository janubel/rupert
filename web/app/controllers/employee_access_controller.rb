# frozen_string_literal: true

class EmployeeAccessController < ApplicationController
  skip_before_action :require_login, only: %i[edit update]
  before_action :private_response

  def create
    raise Pundit::NotAuthorizedError unless Current.user.can_manage_accounts? && Current.user.can?('hr.write')
    @employee = People::Employee.find(params[:employee_id])
    token = EmployeeAccessGrant.issue!(@employee)
    @setup_url = employee_setup_url(token: token)
    ActivityLogger.log('employee_access_link_created', subject: @employee)
    render :created
  rescue TimesheetWorkflow::Error, ActiveRecord::RecordInvalid => e
    redirect_to people_employee_path(params[:employee_id]), alert: e.message
  rescue Pundit::NotAuthorizedError
    render plain: 'Account administration permission is required.', status: :forbidden
  end

  def edit
    @grant = valid_grant
    render plain: 'This setup link has expired or is no longer available. Ask your administrator for another link.', status: :gone unless @grant
  end

  def update
    grant = valid_grant
    return render plain: 'This setup link is no longer available.', status: :gone unless grant
    EmployeeAccessGrant.transaction do
      Tenant.where(id: grant.tenant_id).update_all('updated_at = updated_at')
      grant.reload
      raise TimesheetWorkflow::Error, 'This setup link is no longer available.' unless grant.usable?
      grant.user.update!(password: params[:password], password_confirmation: params[:password_confirmation])
      grant.update!(used_at: Time.current)
      EmployeeAppSession.unscoped.where(user_id: grant.user_id).update_all(revoked_at: Time.current)
    end
    reset_session
    session[:user_id] = grant.user_id
    session[:employee_password_fingerprint] = Digest::SHA256.hexdigest(grant.user.password_digest)
    redirect_to people_timesheets_path, notice: 'Your password is set. Use this account on the web or in the Rupert app.'
  rescue ActiveRecord::RecordInvalid => e
    @grant = grant
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :edit, status: :unprocessable_entity
  rescue TimesheetWorkflow::Error
    render plain: 'This setup link is no longer available.', status: :gone
  end

  private

  def valid_grant
    grant = EmployeeAccessGrant.lookup(params[:token])
    grant if grant&.usable? && (Current.tenant.nil? || Current.tenant.id == grant.tenant_id)
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
