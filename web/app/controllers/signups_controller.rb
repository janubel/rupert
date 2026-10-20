# frozen_string_literal: true

class SignupsController < ApplicationController
  content_security_policy(prepend: true) { |policy| policy.frame_ancestors :none }

  skip_before_action :require_login, only: %i[new create]
  before_action :private_response
  rate_limit to: 10, within: 1.hour, only: :create,
    with: -> { redirect_to(signup_path, alert: 'Too many requests. Please try again later.') }

  def new
    @signup = WorkspaceSignup.new
  end

  def create
    attributes = WorkspaceSignup.intent(params.require(:workspace_signup).permit(:workspace_name, :requested_subdomain, :domain).to_h)
    @signup = WorkspaceSignup.new(attributes.merge(email: "applicant@#{attributes['domain']}", google_subject: 'form-preview',
      applicant_name: 'Applicant', writer_checked: true))
    unless @signup.valid?
      return render(:new, status: :unprocessable_entity)
    end
    session.delete(:registration_intent)
    state = SecureRandom.hex(24)
    session[:oauth_state] = state
    session[:oauth_started_at] = Time.current.to_i
    session[:workspace_signup_intent] = attributes
    redirect_to(GoogleOauthService.auth_url(redirect_uri: google_callback_url, state: state), allow_other_host: true)
  rescue GoogleOauthService::NotConfiguredError => e
    session.delete(:oauth_state)
    session.delete(:oauth_started_at)
    session.delete(:workspace_signup_intent)
    redirect_to(signup_path, alert: e.message)
  end

  private

  def private_response
    response.set_header('X-Frame-Options', 'DENY')
    response.set_header('Cache-Control', 'no-store')
    response.set_header('Referrer-Policy', 'no-referrer')
    response.set_header('X-Robots-Tag', 'noindex, nofollow, noarchive')
  end
end
