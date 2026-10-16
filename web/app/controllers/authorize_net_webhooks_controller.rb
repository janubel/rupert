# frozen_string_literal: true

require 'openssl'

# A callback authenticates itself with the merchant signature, not a user session.
class AuthorizeNetWebhooksController < ActionController::API
  MAX_BYTES = 32_768
  EVENTS = %w[authcapture.created authorization.created capture.created priorAuthCapture.created
    refund.created void.created fraud.approved fraud.declined fraud.held].map { |name| "net.authorize.payment.#{name}" }.freeze

  def create
    response.headers['Cache-Control'] = 'no-store'
    connection = PosConnection.unscoped.find_by(id: request.path_parameters[:connection_id], provider: 'authorize_net_reporting')
    return head(:not_found) unless connection && Tenant.where(id: connection.tenant_id, status: 'active').exists?

    Current.set(tenant: Tenant.find(connection.tenant_id)) do
      return head(:not_found) unless connection.reporting_enabled && connection.vendor_approved && connection.credentials_saved?
      secret = connection.credential_values['signature_key']
      return head(:not_found) unless secret.present?
      return head(:content_too_large) if request.content_length.to_i > MAX_BYTES

      body = request.body.read(MAX_BYTES + 1)
      return head(:content_too_large) if body.bytesize > MAX_BYTES
      supplied = request.headers['X-ANET-Signature'].to_s
      return head(:unauthorized) unless supplied.match?(/\Asha512=[0-9a-f]{128}\z/i)

      # Support the documented decoded Signature Key and legacy text-key callbacks.
      # Both verify the exact raw body with a secret-key HMAC; neither trusts JSON amounts.
      digests = [[secret].pack('H*'), secret].map { |key| OpenSSL::HMAC.hexdigest('SHA512', key, body) }
      verified = digests.map { |digest| ActiveSupport::SecurityUtils.secure_compare(digest, supplied.split('=', 2).last.downcase) }
      return head(:unauthorized) unless verified.any?

      event = JSON.parse(body, max_nesting: 10)
      return head(:bad_request) unless event.is_a?(Hash) && EVENTS.include?(event['eventType']) &&
        event['notificationId'].to_s.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i) &&
        event['payload'].is_a?(Hash) && event['payload']['entityName'] == 'transaction' &&
        event['payload']['id'].to_s.match?(/\A[1-9][0-9]{0,29}\z/)

      # Only an ID enters the queue. Amount/status come from verified API details.
      job = AuthorizeNetEventJob.perform_later(tenant_id: connection.tenant_id, connection_id: connection.id,
        webhook_scope: connection.webhook_scope, transaction_id: event['payload']['id'].to_s)
      head(job ? :ok : :service_unavailable)
    end
  rescue JSON::ParserError, EncodingError
    head(:bad_request)
  rescue ActiveJob::EnqueueError
    head(:service_unavailable)
  end
end
