# frozen_string_literal: true

# Apple's domain check for Apple Pay on the web: Apple fetches this file, without signing in, before it lets the
# checkout domain show the button. The contents come from the APPLE_PAY_DOMAIN_ASSOCIATION setting (pasted from the
# Apple Developer portal), so it survives deploys and stays out of the public repository.
# A bare controller: no session, sign-in or workspace redirects apply to Apple's request.
class ApplePayDomainController < ActionController::Base
  def show
    tenant = Tenant.find_by(subdomain: request.subdomain.presence) || (Tenant.count == 1 ? Tenant.first : nil)
    Current.tenant = tenant
    body = tenant && EnvStore.fetch('APPLE_PAY_DOMAIN_ASSOCIATION', '').to_s.strip
    return head(:not_found) if body.blank?

    expires_in 1.hour, public: true
    render plain: body, content_type: 'text/plain'
  ensure
    Current.reset
  end
end
