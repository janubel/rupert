# frozen_string_literal: true

# Current local setup, separate from an attempt's outcome and schedule opt-in.
# Return only static labels and presence; never values or inferred entitlement.
class SourceReadAccess
  PROVIDER_ACTIONS = {
    'ctrax' => 'Review C-Trax read setup. Use the authorized stock API login, separate from TRX payment credentials.',
    'swipesimple' => 'Review SwipeSimple website setup for the intended company and authorized website login. This does not establish API access.',
    'authorize_net' => 'Review Authorize.net reporting setup and approved reporting access. Portal sign-in does not establish API access; do not rotate a shared payment key.',
    'bank' => 'Review NAB / IRIS setup for the selected website or API method and intended merchant accounts.'
  }.freeze
  ACCOUNT_LABELS = { 'swipesimple' => 'Company ID', 'authorize_net' => 'Gateway ID', 'bank' => 'Merchant IDs' }.freeze
  CREDENTIAL_LABELS = {
    'api_url' => 'API URL', 'api_token' => 'API token', 'api_username' => 'API username', 'api_password' => 'API password',
    'api_login_id' => 'API Login ID', 'transaction_key' => 'Transaction Key',
    'client_id' => 'Client ID', 'client_secret' => 'Client secret', 'refresh_token' => 'Refresh token',
    'web_email' => 'Website email', 'web_username' => 'Website username', 'web_password' => 'Website password'
  }.freeze

  def self.for(source, connection: nil)
    new(source, connection).call
  end

  def initialize(source, connection)
    @source, @connection = source, connection
  end

  def call
    case @source
    when 'shopify', 'square' then managed_access
    when 'google_backup' then backup_access
    else provider_access
    end
  end

  private

  def ready
    { ready: true, state: 'Read setup present', missing_fields: [],
      reason: 'Required local read setup is present',
      action: 'Presence does not prove vendor permission or a successful read. Review acquisition receipts separately.' }
  end

  def missing(fields, action, state: 'Missing access', reason: 'Required read setup is missing')
    { ready: false, state: state, missing_fields: fields, reason: reason,
      action: "#{action} Keep existing credentials and sync settings intact; this page changes neither." }
  end

  def managed_access
    fields = ConnectionCredentials.fields(@source).reject { |field| field[:optional] }
    absent = fields.filter_map { |field| field[:label] if EnvStore.fetch(field[:key], '').blank? }
    return ready if absent.empty?

    action = if @source == 'square'
      'Open Square setup and supply an authorized access token for the intended environment.'
    else
      'Open Shopify setup and supply only the missing fields for the intended store.'
    end
    missing(absent, action)
  end

  def provider_access
    provider = ConnectionControlCenter::SOURCE_SETUP[@source]
    return ready unless provider

    connection = @connection || PosConnection.new(provider: provider)
    values = connection.credential_values
    absent = connection.credential_keys.filter_map { |key| CREDENTIAL_LABELS.fetch(key) if values[key].blank? }
    account_label = ACCOUNT_LABELS[@source]
    absent << account_label if account_label && connection.account_reference.blank?
    absent << 'Read authorization confirmation' unless connection.vendor_approved
    return ready if absent.empty?

    approval_only = absent == ['Read authorization confirmation']
    missing(absent, PROVIDER_ACTIONS.fetch(@source),
      state: approval_only ? 'Read authorization required' : 'Missing access',
      reason: approval_only ? 'Rupert read authorization has not been confirmed' : 'Required read setup is missing')
  end

  def backup_access
    fields = { 'GOOGLE_DRIVE_CLIENT_ID' => 'Backup OAuth client ID', 'GOOGLE_DRIVE_CLIENT_SECRET' => 'Backup OAuth client secret' }
    absent = fields.filter_map { |key, label| label if EnvStore.platform_fetch(key, '').blank? }
    return missing(absent, 'The platform operator must complete the existing Google Drive backup client setup.') if absent.any?
    return ready if EnvStore.platform_fetch('GOOGLE_DRIVE_REFRESH_TOKEN', '').present?

    # The backup service creates a folder after consent; no folder ID is required here.
    missing(['Google Drive backup authorization'], 'The platform operator must complete Connect Google Drive from Backup settings and verify a backup. Document-retention Drive has a separate consent flow.',
      state: 'Authorization required', reason: 'Google Drive backup consent is incomplete')
  end
end
