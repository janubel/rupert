# frozen_string_literal: true

# Google sign-in for the login page. Reaches Google before the user is
# authenticated, so it must skip the usual require_login gate.
#
# Flow:
#   GET /auth/google              → redirect to Google's consent screen
#   GET /auth/google/callback     → exchange code, verify domain, sign in
#
# Domain enforcement: the user's email domain must be in the tenant's
# OauthAllowedDomain list. Unknown domains are rejected; known domains with an
# existing Rupert account sign in, and known domains without one get a employee
# account auto-provisioned. Explicit Google login aliases use their canonical
# account's allowed domain and never create another account. An explicitly
# linked identity matching the account email grants only that account access.
class OauthController < ApplicationController
  include DriveOauthCallback
  include RetentionDriveOauthCallback
  include UploadsDriveOauthCallback
  class AccountInAnotherTenant < StandardError; end

  content_security_policy(prepend: true) { |policy| policy.frame_ancestors :none }

  skip_before_action :require_login, only: %i[authorize callback]

  def authorize
    return redirect_to(WorkspaceNode.control_origin + '/login', allow_other_host: true) if WorkspaceNode.isolated?
    state = SecureRandom.hex(24)
    session[:oauth_state] = state
    session[:oauth_started_at] = Time.current.to_i
    session.delete(:workspace_signup_intent)
    session.delete(:registration_intent)
    # The Rupert iPhone app signs in through a system browser sheet (see NativeSignIn).
    if NativeSignIn.valid_challenge?(params[:native_challenge])
      session[:oauth_native_challenge] = params[:native_challenge]
      kind, fields = NativeSignIn.read_intent(params[:intent])
      session[:registration_intent] = fields if kind == 'registration'
      session[:workspace_signup_intent] = fields if kind == 'workspace_signup'
    else
      session.delete(:oauth_native_challenge)
    end
    AccessLogger.record(source: 'google', status: 'attempt', request: request, detail: 'Google sign-in started')
    redirect_to(
      GoogleOauthService.auth_url(redirect_uri: google_callback_url, state: state),
      allow_other_host: true
    )
  rescue GoogleOauthService::NotConfiguredError => e
    AccessLogger.record(source: 'google', status: 'failure', request: request, detail: 'not configured')
    redirect_to(login_path, alert: e.message)
  end

  def callback
    response.set_header('X-Frame-Options', 'DENY')
    response.set_header('Cache-Control', 'no-store')
    response.set_header('Referrer-Policy', 'no-referrer')
    response.set_header('X-Robots-Tag', 'noindex, nofollow, noarchive')
    # Backup consent reuses the registered callback, without signing in or provisioning users.
    return complete_drive_oauth if params[:state].to_s.start_with?('drive:')
    return complete_retention_drive_oauth if params[:state].to_s.start_with?('retention:')
    return complete_uploads_drive_oauth if params[:state].to_s.start_with?('uploads_drive:')

    info = nil
    @native_challenge = session.delete(:oauth_native_challenge)
    tested_domain = params[:hd].presence
    if params[:error].present?
      clear_oauth_intent
      AccessLogger.record(source: 'google', status: 'failure', request: request, domain: tested_domain,
        detail: 'consent declined')
      return login_failed('Google sign-in was declined.')
    end
    if session[:oauth_state].blank? || session[:oauth_state] != params[:state] ||
        session[:oauth_started_at].to_i < 10.minutes.ago.to_i
      clear_oauth_intent
      AccessLogger.record(source: 'google', status: 'failure', request: request, domain: tested_domain,
        detail: 'state check failed')
      return login_failed('Google sign-in failed the state check. Try again.')
    end

    registration_intent = session.delete(:registration_intent)
    signup_intent = session.delete(:workspace_signup_intent)
    session.delete(:oauth_state)
    session.delete(:oauth_started_at)
    info = GoogleOauthService.exchange_code!(params[:code], redirect_uri: google_callback_url)
    session.delete(:oauth_state)

    if registration_intent
      user = VerifiedWorkspaceRegistration.call(info: info, attributes: registration_intent)
      identity = user.google_login_identities.find_by!(email: user.email)
      return hand_off_to_app(user, user.email, identity, location: workspace_path) if @native_challenge

      start_browser_session(user, method: 'google', google_email: user.email, google_identity: identity)
      return redirect_to(workspace_path, notice: 'Your free account is ready.')
    end

    if signup_intent
      @signup = WorkspaceSignupProvisioner.request_signup(info: info, attributes: signup_intent)
      reset_session
      return redirect_to(NativeSignIn.callback_url(message: signup_receipt_message(@signup)), allow_other_host: true) if @native_challenge

      return render('signups/receipt')
    end

    email = info['email'].to_s.downcase
    tested_domain ||= email.split('@').last
    identity = GoogleLoginIdentity.find_by(email: email)
    if identity && User.where(email: email).where.not(id: identity.user_id).exists?
      raise GoogleOauthService::ExchangeError, 'This Google email has conflicting account links. Contact an admin.'
    end
    tenant = resolve_tenant(email, linked_user: identity&.user)
    allowed_email = identity ? identity.user.email : email
    approved_account = identity&.exact_account_email?
    unless tenant&.status == 'active' && (approved_account || OauthAllowedDomain.allowed?(allowed_email, tenant: tenant))
      AccessLogger.record(
        source: 'google',
        status: 'failure',
        request: request,
        email: email,
        domain: tested_domain,
        detail: 'domain not allowed'
      )
      return login_failed("Your Google account (#{email}) isn't on an allowed domain. Ask an admin to allow #{email.split('@').last}.")
    end

    # Newly approved workspace owners are bound to the verified Google
    # identity submitted for approval, even if their mailbox is reassigned.
    approved_signup = WorkspaceSignup.find_by(tenant_id: tenant.id, email: email, status: 'approved')
    if approved_signup && approved_signup.google_subject != info['sub']
      raise GoogleOauthService::ExchangeError, 'This Google identity does not match the approved workspace owner. Contact the platform owner.'
    end

    user = identity ? identity.user : find_or_create_user!(email, info, tenant)
    unless user&.active?
      AccessLogger.record(
        source: 'google',
        status: 'failure',
        request: request,
        email: email,
        domain: tested_domain,
        detail: 'deactivated account'
      )
      return login_failed('This account has been deactivated. Contact an admin.')
    end

    identity&.verify_subject!(info['sub'])

    return hand_off_to_app(user, email, identity) if @native_challenge

    start_browser_session(user, method: 'google', google_email: email, google_identity: identity)
    AccessLogger.record(source: 'google', status: 'success', request: request, user: user, email: email,
      domain: tested_domain)
    redirect_to(sign_in_landing_path(user), notice: 'Signed in with Google.')
  rescue GoogleOauthService::NotConfiguredError, GoogleOauthService::ExchangeError => e
    clear_oauth_intent
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: info&.dig('email'),
      domain: tested_domain || info&.dig('email')&.split('@')&.last, detail: e.message.to_s[0, 200])
    login_failed(e.message)
  rescue ActiveRecord::RecordInvalid => e
    clear_oauth_intent
    redirect_to(signup_path, alert: e.record.errors.full_messages.to_sentence)
  rescue AccountInAnotherTenant => e
    clear_oauth_intent
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: e.message,
      domain: e.message.to_s.split('@').last, detail: 'account belongs to another tenant')
    login_failed('This Google account already belongs to another workspace. Ask the workspace admin to invite you.')
  rescue StandardError => e
    clear_oauth_intent
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: info&.dig('email'),
      domain: tested_domain || info&.dig('email')&.split('@')&.last, detail: "#{e.class}: #{e.message.to_s[0, 160]}")
    raise
  end

  private

  # A failed sign-in returns to the login page, or to the iPhone app when it started the flow.
  def login_failed(message)
    return redirect_to(NativeSignIn.callback_url(error: message), allow_other_host: true) if @native_challenge

    redirect_to(login_path, alert: message)
  end

  # The app redeems the code with its verifier (Native::SessionsController). The browser sheet
  # gets no Rupert session of its own.
  def hand_off_to_app(user, email, identity, location: nil)
    code = NativeSignIn.issue(user: user, google_email: email, google_identity: identity, challenge: @native_challenge,
      location: location)
    reset_session
    redirect_to(NativeSignIn.callback_url(code: code), allow_other_host: true)
  end

  # The same words as signups/receipt, for the app's alert.
  def signup_receipt_message(signup)
    case signup.status
    when 'approved' then 'Your workspace has been approved. Sign in with the same Google account to continue.'
    when 'rejected' then 'The platform owner did not approve this workspace request.'
    else 'Your workspace request is waiting for platform owner review. You have not been signed in.'
    end
  end

  def clear_oauth_intent
    session.delete(:oauth_native_challenge)
    session.delete(:registration_intent)
    session.delete(:oauth_state)
    session.delete(:oauth_started_at)
    session.delete(:workspace_signup_intent)
  end

  # Root sign-in follows the globally unique exact account first. New employees
  # need one unambiguous active tenant domain; never pick an arbitrary store.
  def resolve_tenant(email, linked_user: nil)
    existing = linked_user || User.find_by(email: email)
    if Current.tenant
      raise AccountInAnotherTenant, email if existing && existing.tenant_id != Current.tenant.id

      return Current.tenant
    end
    return existing.tenant if existing

    tenant_ids = OauthAllowedDomain.unscoped.where(domain: email.split('@').last).distinct.pluck(:tenant_id)
    return unless tenant_ids.one?

    Tenant.find_by(id: tenant_ids.first, status: 'active')
  end

  # A user's account is tenant-scoped: resolve to the account in the subdomain's
  # tenant, never a same-email account belonging to another tenant.
  def find_or_create_user!(email, info, tenant)
    user = User.find_by(email: email, tenant_id: tenant.id)
    return user if user

    raise AccountInAnotherTenant, email if User.exists?(email: email)

    user = tenant.users.new(
      email: email,
      name: info['name'].presence || email.split('@').first.titleize,
      role: 'employee',
      referral_domain: WorkspaceSignup::REFERRAL_DOMAIN,
      password: SecureRandom.hex(24)
    )
    user.save!
    ActivityLogger.log('employee_added', subject: user, details: 'via Google sign-in')
    user
  end
end
