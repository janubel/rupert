# frozen_string_literal: true

class RegistrationsController < ApplicationController
  skip_before_action :require_login
  before_action { response.headers['Cache-Control'] = 'no-store' }
  rate_limit to: 10, within: 1.hour, only: :create
  def new
    head :not_found if WorkspaceNode.isolated?
  end

  def create
    return head :not_found if WorkspaceNode.isolated?
    fields = params.require(:registration).permit(:workspace_name, :requested_subdomain).to_h.transform_values { |value| value.to_s.strip }
    tenant = Tenant.new(name: fields['workspace_name'], subdomain: fields['requested_subdomain'])
    unless tenant.valid? && !WorkspaceSignup::RESERVED_SUBDOMAINS.include?(tenant.subdomain)
      flash.now[:alert] = 'Choose a company name and an available workspace address (2–63 lowercase letters, numbers or hyphens).'
      return render(:new, status: :unprocessable_entity)
    end
    session[:oauth_state] = SecureRandom.hex(24)
    session[:oauth_started_at] = Time.current.to_i
    session.delete(:workspace_signup_intent)
    session[:registration_intent] = fields
    redirect_to GoogleOauthService.auth_url(redirect_uri: google_callback_url, state: session[:oauth_state]), allow_other_host: true
  rescue GoogleOauthService::NotConfiguredError => e
    session.delete(:registration_intent)
    session.delete(:oauth_state)
    session.delete(:oauth_started_at)
    redirect_to start_path, alert: e.message
  end
end
