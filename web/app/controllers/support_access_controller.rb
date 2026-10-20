# frozen_string_literal: true

class SupportAccessController < AuthenticatedController
  before_action :require_customer_owner
  before_action { response.headers['Cache-Control'] = 'no-store' }
  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end
  def index
    @grants = SupportAccessGrant.where(tenant: Current.tenant).includes(:support_user).order(id: :desc).limit(30)
    @events = SupportAccessEvent.where(tenant: Current.tenant).includes(:actor).order(id: :desc).limit(50)
    @operators = User.where(role: 'super_admin', active: true).order(:email)
  end

  def create
    SupportAccessGrant.transaction do
      grant = SupportAccessGrant.create!(tenant: Current.tenant, granted_by: Current.user,
        support_user: User.find(params[:support_user_id]), reason: params[:reason].to_s, expires_at: 1.hour.from_now)
      CustomerSupportAccess.record!(actor: Current.user, tenant: Current.tenant, grant: grant, action: 'granted')
    end
    redirect_to support_access_path, notice: 'Read access granted for one hour. You can revoke it at any time.'
  rescue ActiveRecord::RecordInvalid
    redirect_to support_access_path, alert: 'Choose an active support administrator and enter a reason (up to 300 characters).'
  end

  def destroy
    SupportAccessGrant.transaction do
      grant = SupportAccessGrant.find_by!(id: params[:id], tenant: Current.tenant)
      grant.update_columns(revoked_at: Time.current, updated_at: Time.current)
      CustomerSupportAccess.record!(actor: Current.user, tenant: Current.tenant, grant: grant, action: 'revoked')
    end
    redirect_to support_access_path, notice: 'Support access revoked.'
  end

  private

  def require_customer_owner
    head :forbidden unless Current.user&.admin? && Current.user.tenant_id == Current.tenant&.id
  end
end
