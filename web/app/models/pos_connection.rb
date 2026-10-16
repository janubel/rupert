# frozen_string_literal: true

require 'json'
require 'uri'

class PosConnection < ApplicationRecord
  include TenantScoped

  GATEWAYS = %w[unconfirmed authorize_net nmi swipesimple other].freeze
  SETUP_FIELDS = %w[environment account_reference gateway access_requested vendor_approved credentials_json hourly_sync_enabled reporting_auth_mode reporting_enabled].freeze

  encrypts :credentials_json
  belongs_to :updated_by, class_name: 'User', optional: true
  attr_readonly :tenant_id, :provider

  validates :tenant_id, presence: true
  validates :provider, inclusion: { in: PosProviderCatalog.all.pluck(:key) }, uniqueness: { scope: :tenant_id }
  validates :environment, inclusion: { in: %w[sandbox production] }
  validates :gateway, inclusion: { in: GATEWAYS }
  validates :account_reference, length: { maximum: 200 }
  validates :last_check_status, inclusion: { in: %w[verified failed] }, allow_nil: true
  validates :reporting_auth_mode, inclusion: { in: %w[api_key oauth] }
  validate :valid_reporting_setup
  validate :valid_credentials
  before_validation :invalidate_check_on_setup_change

  def definition
    PosProviderCatalog.find(provider)
  end

  def credential_keys
    if provider == 'authorize_net_reporting'
      return reporting_auth_mode == 'oauth' ? %w[client_id client_secret refresh_token] : %w[api_login_id transaction_key]
    end
    PosProviderCatalog.credential_keys(provider, gateway: gateway)
  end

  def check_kind
    PosProviderCatalog.check_kind(provider, gateway: gateway)
  end

  def gateway_details
    PosProviderCatalog.gateway_details(provider, gateway: gateway)
  end

  def credential_values
    value = JSON.parse(credentials_json.presence || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  def apply_setup(attributes, submitted_credentials)
    previous = credential_values
    assign_attributes(attributes)
    previous = {} if environment_changed? || gateway_changed? || reporting_auth_mode_changed?
    supplied = submitted_credentials.to_h.stringify_keys.slice(*credential_keys)
                                    .reject { |_key, value| value.blank? }
    values = previous.merge(supplied)
    values['api_url'] = values['api_url'].delete_suffix('/') if %w[korona
                                                                   ctrax iris_reporting].include?(provider) && values['api_url'].is_a?(String)
    self.credentials_json = JSON.generate(values)
  end

  def credentials_saved?
    return false if errors.any?

    credential_keys.any? && credential_keys.all? { |key| credential_values[key].present? }
  end

  def status_label
    return 'Setup changes not saved' if errors.any?

    return 'Reporting access checked' if provider == 'authorize_net_reporting' && credentials_saved? && last_check_status == 'verified'

    if credentials_saved? && last_check_status == 'verified'
      return 'API credentials checked' if check_kind == 'authorize_net'
      return 'Merchant profile read access checked' if check_kind == 'nmi'

      return 'Read access checked'
    end
    if credentials_saved? && last_check_status == 'failed'
      return 'API credential check failed' if check_kind == 'authorize_net'
      return 'Merchant profile check failed' if check_kind == 'nmi'

      return 'Read check failed'
    end
    return 'Credentials saved · not checked' if credentials_saved?
    return 'Waiting for vendor access' if access_requested && !vendor_approved
    return 'Setup details saved' if persisted?

    'Not configured'
  end

  private

  def valid_reporting_setup
    if provider == 'ctrax'
      errors.add(:base, 'Save approved C-Trax read credentials before enabling daily sales pulls.') if reporting_enabled && (!vendor_approved || !credentials_saved?)
      return
    end
    if provider == 'swipesimple'
      if credential_values.any? || reporting_enabled
        errors.add(:account_reference, 'must be the numeric SwipeSimple company ID') unless account_reference.to_s.match?(/\A[1-9][0-9]{0,19}\z/)
      end
      errors.add(:environment, 'must be production for SwipeSimple Web') unless environment == 'production'
      errors.add(:base, 'Save an authorized website login before enabling scheduled pulls.') if reporting_enabled && (!vendor_approved || !credentials_saved?)
      return
    end
    if provider == 'iris_reporting'
      begin
        IrisReporting::Client.merchants(account_reference) if account_reference.present? || credential_values.any? || reporting_enabled
      rescue IrisReporting::Client::Error
        errors.add(:account_reference, 'must contain up to 10 distinct numeric merchant IDs separated by commas')
      end
      errors.add(:environment, 'must be production for IRIS') unless environment == 'production'
      errors.add(:base, 'Save approved IRIS API credentials before enabling scheduled reports.') if reporting_enabled && (!vendor_approved || !credentials_saved?)
      return
    end
    return unless provider == 'authorize_net_reporting'
    if credential_values.any? || reporting_enabled
      errors.add(:account_reference, 'must be the numeric Authorize.net Gateway ID') unless account_reference.to_s.match?(/\A[1-9][0-9]{0,29}\z/)
    end
    errors.add(:base, 'Save approved reporting credentials before enabling daily reconciliation.') if reporting_enabled && (!vendor_approved || !credentials_saved?)
    if reporting_auth_mode == 'api_key' && credential_values.any?
      errors.add(:base, 'Use an API Login ID of at most 25 characters and a Transaction Key of at most 16 characters.') if credential_values['api_login_id'].to_s.bytesize > 25 || credential_values['transaction_key'].to_s.bytesize > 16
    end
  end

  def invalidate_check_on_setup_change
    return unless SETUP_FIELDS.any? { |field| will_save_change_to_attribute?(field) }

    self.last_report_status = nil
    self.last_report_message = nil
    self.last_reported_at = nil
    self.last_check_status = nil
    self.last_check_message = nil
    self.last_checked_at = nil
  end

  def valid_credentials
    values = credential_values
    allowed = credential_keys
    if credentials_json.to_s.bytesize > 16_384 || (values.keys - allowed).any? || values.values.any? do |value|
      !value.is_a?(String) || !value.valid_encoding? || value.bytesize > 4096 || value.match?(/[\x00-\x1f\x7f]/)
    end
      errors.add(:base, 'The connection credentials are unsupported or too long.')
      return
    end
    return if values.empty?

    errors.add(:base, provider == 'swipesimple' ? 'Authorize website read access before saving credentials.' : 'Confirm approved API read access before saving credentials.') unless vendor_approved
    errors.add(:base, 'Provide all required credential fields.') unless allowed.all? { |key| values[key].present? }
    if provider == 'swipesimple'
      errors.add(:base, 'Enter a valid SwipeSimple account email.') unless values['web_email'].to_s.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
    elsif provider == 'iris_reporting'
      errors.add(:base, 'Use an HTTPS IRIS tenant origin and an API token, without spaces or control characters.') unless IrisReporting::Client.valid_credentials?(values)
    elsif provider == 'ctrax'
      unless Ctrax::Client.valid_credentials?(values)
        errors.add(:base,
          'Use a C-Trax API origin such as https://your-store.api.cannatrax.net and valid C-Trax user credentials.')
      end
    elsif provider == 'korona'
      unless values['api_url'].to_s.bytesize <= 2048 && PaymentProviders::KoronaCheck::API_URL_PATTERN.match?(values['api_url'].to_s)
        errors.add(:base,
          'Use the exact HTTPS KORONA API endpoint shown in your API widget.')
      end
      if values['api_username'].to_s.bytesize > 512 || values['api_username'].to_s.include?(':')
        errors.add(:base,
          'Use a dedicated API username of at most 512 bytes without a colon.')
      end
      unless values['account_id'].to_s.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
        errors.add(:base,
          'Use the account UUID from KORONA.')
      end
    elsif check_kind == 'authorize_net'
      if values['api_login_id'].to_s.bytesize > 20
        errors.add(:base,
          'Use an Authorize.net API Login ID of at most 20 characters.')
      end
      if values['transaction_key'].to_s.bytesize > 16
        errors.add(:base,
          'Use an Authorize.net transaction key of at most 16 characters.')
      end
    elsif provider == 'cova'
      unless values['company_id'].to_s.match?(/\A[1-9][0-9]{0,9}\z/) && values['company_id'].to_i <= 2_147_483_647
        errors.add(:base,
          'Use the positive Company ID from your Cova onboarding package.')
      end
    end
    errors.add(:base, 'Hourly stock sync is only supported for C-Trax.') if hourly_sync_enabled && provider != 'ctrax'
  end
end
