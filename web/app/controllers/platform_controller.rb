# frozen_string_literal: true

class PlatformController < AuthenticatedController
  content_security_policy(prepend: true) { |policy| policy.frame_ancestors :none }
  prepend_before_action :prevent_caching
  before_action :require_platform_owner
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::StaleObjectError, with: :stale_request
  rescue_from ActionController::ParameterMissing, with: :invalid_form
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_request

  def index
    subscriptions = CustomerSubscription.joins(:tenant).includes(:tenant)
    if params[:customer].present?
      query = ActiveRecord::Base.sanitize_sql_like(params[:customer].to_s.strip.downcase.first(100))
      subscriptions = subscriptions.where('LOWER(tenants.name) LIKE ? OR LOWER(tenants.subdomain) LIKE ?', "%#{query}%", "%#{query}%")
    end
    subscriptions = subscriptions.where(status: params[:billing_status]) if params[:billing_status].present?
    @subscriptions = subscriptions.order(updated_at: :desc).limit(50)
    @billing_totals = CustomerSubscription.group(:status).count
    @support_grants = SupportAccessGrant.current.where(support_user_id: Current.user.id).includes(:tenant).order(expires_at: :asc).limit(30)
    @support_events = SupportAccessEvent.includes(:actor).order(id: :desc).limit(30)
    @operator_identities = GoogleLoginIdentity.includes(:user).where(email: PlatformOwnerIdentities.emails)
    @overview = InstanceOverview.call(actor: Current.user, before_signup_id: params[:before_signup_id])
  rescue ArgumentError
    invalid_form
  end

  def enter_support
    tenant = Tenant.find(params[:id])
    grant = CustomerSupportAccess.grant_for(actor: Current.user, tenant: tenant)
    return head :forbidden unless grant && tenant.status == 'active'
    session[:support_tenant_id] = tenant.id
    CustomerSupportAccess.record!(actor: Current.user, tenant: tenant, grant: grant, action: 'viewed', resource: 'support_session')
    redirect_to inventory_index_path, notice: 'Customer-authorized read-only support session started.'
  end

  def leave_support
    session.delete(:support_tenant_id)
    redirect_to platform_path, notice: 'Support session ended.'
  end

  def approve
    signup = WorkspaceSignup.find(params[:id])
    WorkspaceSignupProvisioner.approve(signup: signup, actor: Current.user, lock_version: params.require(:lock_version))
    redirect_to(platform_path, notice: 'Workspace approved. Its owner can sign in with the approved Google identity; no message was sent.')
  end

  def reject
    signup = WorkspaceSignup.find(params[:id])
    WorkspaceSignupProvisioner.reject(signup: signup, actor: Current.user, lock_version: params.require(:lock_version))
    redirect_to(platform_path, notice: 'Signup request rejected. No workspace was created and no message was sent.')
  end

  private

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['X-Robots-Tag'] = 'noindex, nofollow, noarchive'
    response.headers['X-Frame-Options'] = 'DENY'
  end

  def require_platform_owner
    actor = User.find_by(id: Current.user&.id, active: true, role: 'super_admin')
    workspace = Tenant.find_by(id: actor&.tenant_id, status: 'active')
    unless actor && workspace
      render(plain: 'An active platform administrator and home workspace are required.', status: :forbidden)
      return
    end

    Current.user = actor
    Current.tenant = workspace
  end

  def not_found
    render(plain: 'Private platform record not found.', status: :not_found)
  end

  def stale_request
    redirect_to(platform_path, alert: 'This request changed or was already reviewed. Reload its current status before trying again.')
  end

  def invalid_form
    render(plain: 'Reload the private dashboard and submit the current review form.', status: :bad_request)
  end

  def invalid_request
    redirect_to(platform_path, alert: 'The workspace could not be created. Review the request for an existing domain, email or workspace address; no partial setup was saved.')
  end
end
