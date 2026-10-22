# frozen_string_literal: true

# Records authentication attempts for the access log. Never raises, so a
# logging hiccup can't break login.
class AccessLogger
  class << self
    def record(source:, status:, request:, email: nil, user: nil, detail: nil, domain: nil)
      log_event(source, status, request, email, user, detail)
      AccessLog.create!(
        tenant_id: Current.tenant_id || user&.tenant_id,
        user_id: user&.id,
        email: email.presence || user&.email,
        domain: domain,
        source: source,
        status: status,
        ip: request.remote_ip,
        user_agent: request.user_agent&.to_s&.slice(0, 255),
        detail: detail
      )
    rescue StandardError
      nil
    end

    private

    # The same facts as the access log row, for the structured log. The address is only
    # ever written as a short hash so repeated failures can still be correlated.
    def log_event(source, status, request, email, user, detail)
      OpsLog.event('auth', level: status.to_s == 'failure' ? :warn : :info, source: source, status: status, reason: OpsLog.safe_text(detail, 60).presence,
        user_id: user&.id, tenant_id: Current.tenant_id || user&.tenant_id, email_hash: (OpsLog.email_hash(email) unless user), ip: request.remote_ip)
    end
  end
end
