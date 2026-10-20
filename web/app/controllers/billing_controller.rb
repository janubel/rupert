# frozen_string_literal: true

class BillingController < AuthenticatedController
  before_action :redirect_isolated_billing
  before_action :require_workspace_owner
  before_action { response.headers['Cache-Control'] = 'no-store' }
  rescue_from RupertBilling::Error do |error|
    redirect_to billing_path, alert: error.message
  end
  def show
    @subscription = CustomerSubscription.find_by(tenant: Current.tenant)
    @referral = CustomerReferral.find_by(tenant: Current.tenant)
  end

  def checkout
    url = RupertBilling.checkout(tenant: Current.tenant, actor: Current.user, plan: params[:plan].to_s,
      referral_code: params[:referral_code], accepted: params[:accepted])
    redirect_to url, allow_other_host: true, status: :see_other
  end

  def referral
    if CustomerReferral.approved_codes.any?
      existing = CustomerReferral.find_by(tenant: Current.tenant, active: true)
      if existing && CustomerReferral.approved_codes.include?(existing.code)
        return redirect_to billing_path, notice: 'Your referral code is ready.'
      end
      return redirect_to billing_path, alert: 'Referral invitations are currently issued by Rupert support.'
    end
    unless CustomerSubscription.exists?(tenant: Current.tenant, status: 'active')
      return redirect_to billing_path, alert: 'Referral codes are available to active paying customers.'
    end
    CustomerReferral.find_or_create_by!(tenant: Current.tenant) { |row| row.code = "RUPERT-#{SecureRandom.hex(6).upcase}" }
    redirect_to billing_path, notice: 'Your referral code is ready.'
  end

  def portal
    row = CustomerSubscription.find_by!(tenant: Current.tenant)
    raise RupertBilling::Error, 'No billing customer exists yet.' if row.stripe_customer_id.blank?
    # A dedicated portal configuration must disable cancellation/plan changes during commitments.
    config = ENV['CSP_STRIPE_PORTAL_CONFIGURATION_ID'].presence
    raise RupertBilling::Error, 'Contact support for subscription changes.' unless config
    raise RupertBilling::Error, 'Contact support for changes during your annual commitment.' if row.commitment_ends_at && row.commitment_ends_at > Time.current
    result = RupertBilling.api(:post, 'billing_portal/sessions', { 'customer' => row.stripe_customer_id, 'configuration' => config,
      'return_url' => "#{ENV.fetch('RUPERT_PUBLIC_ORIGIN', 'https://rupertpos.com')}/billing" })
    redirect_to RupertBilling.trusted_url!(result['url'], 'billing.stripe.com'), allow_other_host: true, status: :see_other
  end

  private

  def redirect_isolated_billing
    redirect_to(WorkspaceNode.control_origin + '/billing', allow_other_host: true) if WorkspaceNode.isolated?
  end

  def require_workspace_owner
    head :forbidden unless Current.user&.admin? && Current.user.tenant_id == Current.tenant&.id
  end
end
