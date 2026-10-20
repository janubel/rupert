# frozen_string_literal: true

# A verified mailbox grants only its own workspace, never a whole email domain.
class VerifiedWorkspaceRegistration
  def self.call(info:, attributes:)
    unless [true, 'true'].include?(info['email_verified']) && info['sub'].present?
      raise GoogleOauthService::ExchangeError, 'A verified Google identity is required.'
    end
    email = info['email'].to_s.strip.downcase
    raise GoogleOauthService::ExchangeError, 'This account already exists. Use Sign in.' if User.exists?(email: email) || GoogleLoginIdentity.exists?(email: email)
    # Never turn a customer registration into a privileged operator account.
    if PlatformOwnerIdentities.emails.include?(email)
      raise GoogleOauthService::ExchangeError, 'Use your existing administrator sign-in or ask an operator to link this identity.'
    end
    Tenant.transaction do
      tenant = Tenant.create!(name: attributes.fetch('workspace_name'), subdomain: attributes.fetch('requested_subdomain'))
      user = User.create!(tenant: tenant, email: email, name: info['name'].presence || email, role: 'admin', active: true, password: SecureRandom.hex(32))
      GoogleLoginIdentity.create!(user: user, email: email, google_subject: info['sub'])
      CustomerSubscription.create!(tenant: tenant)
      Current.set(tenant: tenant) { Finance::ChartOfAccounts.seed! }
      user
    end
  rescue ActiveRecord::RecordNotUnique
    raise GoogleOauthService::ExchangeError, 'This account or workspace address already exists. Sign in or choose another address.'
  end
end
