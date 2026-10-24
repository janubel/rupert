# frozen_string_literal: true

# Hands a Google sign-in from the system browser sheet to the Rupert iPhone app.
#
# Google refuses sign-in inside embedded web views, so the app runs /auth/google in
# ASWebAuthenticationSession with `native_challenge` = base64url(SHA-256(verifier)), where the
# verifier is a random secret that never leaves the app (the PKCE pattern, RFC 7636).
# After the usual Google checks, OauthController#callback does not start a session in that sheet.
# It redirects to rupert://auth/google?code=CODE instead. CODE is encrypted, expires in two
# minutes and is accepted once, and only together with the verifier (Native::SessionsController).
# Another app that intercepts the redirect cannot use the code without the verifier.
module NativeSignIn
  CALLBACK = 'rupert://auth/google'
  CHALLENGE = /\A[A-Za-z0-9_-]{43}\z/
  VERIFIER = /\A[A-Za-z0-9._~-]{43,128}\z/
  TTL = 2.minutes
  PURPOSE = :native_google_sign_in

  class Invalid < StandardError; end

  module_function

  def valid_challenge?(value)
    value.is_a?(String) && CHALLENGE.match?(value)
  end

  def challenge_for(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def issue(user:, google_email:, google_identity:, challenge:)
    raise ArgumentError, 'invalid challenge' unless valid_challenge?(challenge)

    payload = {
      'user_id' => user.id,
      'email' => google_email,
      'identity_id' => google_identity&.id,
      'challenge' => challenge,
      'jti' => SecureRandom.hex(16)
    }
    encryptor.encrypt_and_sign(payload, expires_in: TTL, purpose: PURPOSE)
  end

  def callback_url(code: nil, error: nil)
    query = code ? { code: code } : { error: error.to_s[0, 200] }
    "#{CALLBACK}?#{query.to_query}"
  end

  # Returns [user, google_email, google_identity] or raises Invalid.
  def redeem(code, verifier)
    raise Invalid unless code.is_a?(String) && verifier.is_a?(String) && VERIFIER.match?(verifier)

    payload = encryptor.decrypt_and_verify(code, purpose: PURPOSE)
    raise Invalid unless payload.is_a?(Hash)
    raise Invalid unless ActiveSupport::SecurityUtils.secure_compare(challenge_for(verifier), payload['challenge'].to_s)
    raise Invalid unless Rails.cache.write("native-sign-in:#{payload['jti']}", true, unless_exist: true, expires_in: TTL + 1.minute)

    user = User.find_by(id: payload['user_id'])
    raise Invalid unless user&.active?

    identity = nil
    if payload['identity_id']
      identity = GoogleLoginIdentity.find_by(id: payload['identity_id'], user_id: user.id)
      raise Invalid unless identity
    end
    [user, payload['email'], identity]
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
    raise Invalid
  end

  def encryptor
    ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('rupert native google sign-in', 32))
  end
end
