# frozen_string_literal: true

module Native
  # POST /native/session {code, verifier}: the iPhone app trades the one-time code from the
  # Google sheet (see NativeSignIn) for an ordinary Rupert browser session. The app copies the
  # session cookie into its web view. Protected by the code and its verifier, not by a CSRF token:
  # the request comes from the app's own HTTP client, never from a page.
  class SessionsController < ApplicationController
    skip_before_action :require_login
    skip_forgery_protection

    def create
      response.set_header('Cache-Control', 'no-store')
      user, email, identity = NativeSignIn.redeem(params[:code], params[:verifier])
      start_browser_session(user, method: 'google', google_email: email, google_identity: identity)
      AccessLogger.record(source: 'google', status: 'success', request: request, user: user, email: email,
        domain: email.to_s.split('@').last, detail: 'iPhone app')
      render json: { location: sign_in_landing_path(user) }
    rescue NativeSignIn::Invalid
      AccessLogger.record(source: 'google', status: 'failure', request: request, detail: 'iPhone app sign-in code rejected')
      render json: { error: 'That sign-in expired. Sign in with Google again.' }, status: :unprocessable_entity
    end
  end
end
