# frozen_string_literal: true

require 'timeout'
require 'socket'
require 'openssl'

class SyncFailure
  GUIDANCE = {
    'configuration' => ['Setup incomplete', 'Review the account, environment and required saved fields. Save only intended changes, then check read access.'],
    'credentials' => ['Credentials rejected', 'Check this connection’s saved login or integration credentials and environment. Do not rotate a shared payment key without coordinating its consumers.'],
    'entitlement' => ['Read permission denied', 'Ask the vendor or account administrator to confirm this account’s reporting scope. A portal login does not establish API entitlement.'],
    'access' => ['Vendor access denied', 'Review the intended account, environment, saved authentication and granted read scopes with the account administrator. The vendor code alone does not distinguish all of these causes.'],
    'vendor' => ['Vendor service failure', 'Check the vendor’s service status and retry after recovery. Keep the current credentials and previous snapshots.'],
    'optional_reports' => ['Some optional reports unavailable', 'Review the report page for unavailable kinds and confirm vendor entitlement or collection compatibility. Missing optional reports do not mean zero activity.'],
    'verification' => ['Additional sign-in verification', 'Complete the vendor’s sign-in verification, check read access, then deliberately review the existing schedule.'],
    'identity' => ['Source account mismatch', 'Review the intended company or merchant in setup. Keep previous snapshots; do not import a different account to clear this failure.'],
    'data_contract' => ['Unexpected or incomplete source data', 'Keep the previous snapshots. Ask the operator to inspect the connector contract, pagination and export validation before retrying.'],
    'rate_limit' => ['Vendor rate limit', 'Wait for the recorded retry or existing schedule. Avoid repeated manual reads; ask the operator to review request frequency if this repeats.'],
    'read_limit' => ['Read limit exceeded', 'Use a smaller supported window where available. Ask the operator to review size/time limits; never accept truncated data.'],
    'network' => ['Network or secure connection failure', 'Check vendor availability and server connectivity/TLS. Retry one read after connectivity is restored; keep saved credentials.'],
    'timeout' => ['Request timed out', 'Check vendor availability and server connectivity. Retry once after recovery; a timeout does not prove credentials are wrong.'],
    'setup_changed' => ['Setup changed during read', 'Reload setup and run one read with its current saved configuration. Do not restore an older credential copy.'],
    'encryption' => ['Saved credentials unreadable', 'Ask the platform operator to restore the original encryption keys from the protected backup. Do not overwrite credentials or generate new encryption keys.'],
    'storage' => ['Local storage failure', 'Ask the operator to inspect database availability, disk space and locks. Preserve credentials and source snapshots.'],
    'worker' => ['Job did not complete', 'Ask the operator to inspect the worker, queue and this support reference before retrying. Do not change credentials to repair a worker failure.'],
    'unknown' => ['Cause not recorded precisely', 'Review the source setup and job history with the operator. Do not assume bad credentials; the next instrumented read will record a safe category.']
  }.freeze
  REASONS = {
    invalid: 'configuration', login: 'credentials', unauthorized: 'credentials',
    forbidden: 'entitlement', unavailable: 'entitlement', verification: 'verification',
    identity: 'identity', response: 'data_contract', rate_limit: 'rate_limit',
    limit: 'read_limit', network: 'network', stale: 'setup_changed', changed: 'setup_changed',
    vendor: 'vendor', access: 'access'
  }.freeze

  def self.category(error)
    return 'encryption' if error.is_a?(ActiveRecord::Encryption::Errors::Decryption)
    return 'storage' if error.is_a?(ActiveRecord::ActiveRecordError)
    return 'timeout' if error.is_a?(Timeout::Error)
    return 'data_contract' if error.is_a?(JSON::ParserError)
    return 'network' if error.is_a?(SocketError) || error.is_a?(OpenSSL::SSL::SSLError)

    known = [Ctrax::Client::Error, SwipesimpleWeb::Client::Error, IrisReporting::Client::Error,
      IrisReporting::WebClient::Error, AuthorizeNetReporting::Client::Error, ShopifyClient::Error, SquareClient::Error]
    return REASONS.fetch(error.reason, 'unknown') if known.any? { |type| error.is_a?(type) } && error.respond_to?(:reason)

    'unknown'
  end

  def self.http_reason(code)
    { '401' => :unauthorized, '403' => :forbidden, '429' => :rate_limit }.fetch(code.to_s) do
      code.to_i >= 500 ? :vendor : :response
    end
  end
end
