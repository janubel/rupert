# frozen_string_literal: true

require 'signet/oauth_2/client'
require 'net/http'
require 'json'

# Google sign-in (OpenID Connect) for the login page. Mirrors the Signet-based
# flow already used by GoogleDriveBackupService: build an authorization URL,
# exchange the callback code for an access token, then read the user's profile
# (email + name) from Google's userinfo endpoint.
#
# Configuration (Settings page / EnvStore):
#   GOOGLE_OAUTH_CLIENT_ID     OAuth client ID from Google Cloud Console
#   GOOGLE_OAUTH_CLIENT_SECRET matching client secret
#
# Which email domains may sign in is enforced separately by
# OauthAllowedDomain — this service only exchanges the code and returns
# the verified Google profile.
class GoogleOauthService
  class NotConfiguredError < StandardError; end
  class ExchangeError < StandardError; end

  SCOPE = 'openid email profile'

  class << self
    # The one host whose callback is registered with Google. Every Google sign-in and sign-up
    # runs there, so pos.rupertpos.com, rupertpos.com and the iPhone app need no callback of their
    # own. RUPERT_GOOGLE_OAUTH_HOST, else the canonical HOST in production; nil means "any host".
    def sign_in_host
      configured = ENV['RUPERT_GOOGLE_OAUTH_HOST'].presence
      configured ||= ENV['HOST'].presence if Rails.env.production?
      return nil if configured.blank?

      (configured.include?('://') ? URI(configured).host : configured.split('/').first).presence&.downcase
    rescue URI::InvalidURIError
      nil
    end

    # Whether a sign-in that starts on `host` has to move to sign_in_host first.
    def sign_in_elsewhere?(host)
      target = sign_in_host
      target.present? && target != host.to_s.downcase
    end

    def configured?
      client_id.present? && client_secret.present?
    end

    def auth_url(redirect_uri:, state: nil)
      require_credentials!
      client = signet
      client.redirect_uri = redirect_uri
      params = { access_type: 'online', prompt: 'select_account' }
      params[:state] = state if state.present?
      client.authorization_uri(params).to_s
    end

    # Exchanges the one-time callback code for an access token and returns
    # the verified Google profile as { "email" => ..., "name" => ..., ... }.
    def exchange_code!(code, redirect_uri:)
      require_credentials!
      client = signet
      client.redirect_uri = redirect_uri
      client.code = code
      begin
        client.fetch_access_token!
      rescue Signet::AuthorizationError => e
        raise ExchangeError, "Google rejected the authorization code: #{e.message}"
      end

      userinfo(client.access_token)
    end

    def userinfo(access_token)
      uri = URI('https://openidconnect.googleapis.com/v1/userinfo')
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
      raise ExchangeError, "Google userinfo failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

      profile = JSON.parse(response.body)
      unless [true, 'true'].include?(profile['email_verified']) &&
          profile['email'].to_s.match?(URI::MailTo::EMAIL_REGEXP) && profile['sub'].present?
        raise ExchangeError, 'Google did not return a verified account email. Verify your email with Google before signing in.'
      end
      profile
    end

    private

    def require_credentials!
      return if configured?

      raise NotConfiguredError,
        'Google sign-in is not configured (set GOOGLE_OAUTH_CLIENT_ID / CLIENT_SECRET)'
    end

    def client_id
      EnvStore.fetch('GOOGLE_OAUTH_CLIENT_ID', '')
    end

    def client_secret
      EnvStore.fetch('GOOGLE_OAUTH_CLIENT_SECRET', '')
    end

    def signet
      Signet::OAuth2::Client.new(
        client_id: client_id,
        client_secret: client_secret,
        scope: SCOPE,
        authorization_uri: 'https://accounts.google.com/o/oauth2/auth',
        token_credential_uri: 'https://oauth2.googleapis.com/token'
      )
    end
  end
end
