# frozen_string_literal: true

require 'json'
require 'uri'

class PosConnection < ApplicationRecord
  include TenantScoped

  GATEWAYS = %w[unconfirmed authorize_net nmi swipesimple other].freeze
  SETUP_FIELDS = %w[environment account_reference gateway access_requested vendor_approved credentials_json].freeze

  encrypts :credentials_json
  belongs_to :updated_by, class_name: 'User', optional: true
  attr_readonly :tenant_id, :provider

  validates :tenant_id, presence: true
  validates :provider, inclusion: { in: PosProviderCatalog.all.pluck(:key) }, uniqueness: { scope: :tenant_id }
  validates :environment, inclusion: { in: %w[sandbox production] }
  validates :gateway, inclusion: { in: GATEWAYS }
  validates :account_reference, length: { maximum: 200 }
  validates :last_check_status, inclusion: { in: %w[verified failed] }, allow_nil: true
  validate :valid_credentials
  before_save :invalidate_check_on_setup_change

  def definition
    PosProviderCatalog.find(provider)
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
    previous = {} if environment_changed?
    supplied = submitted_credentials.to_h.stringify_keys.slice(*definition.fetch(:credentials))
      .reject { |_key, value| value.blank? }
    values = previous.merge(supplied)
    values['api_url'] = values['api_url'].delete_suffix('/') if provider == 'korona' && values['api_url'].is_a?(String)
    self.credentials_json = JSON.generate(values)
  end

  def credentials_saved?
    definition && definition[:credentials].any? && definition[:credentials].all? { |key| credential_values[key].present? }
  end

  def status_label
    return 'Read access checked' if credentials_saved? && last_check_status == 'verified'
    return 'Read check failed' if credentials_saved? && last_check_status == 'failed'
    return 'Credentials saved · not checked' if credentials_saved?
    return 'Waiting for vendor access' if access_requested && !vendor_approved
    return 'Setup details saved' if persisted?

    'Not configured'
  end

  private

  def invalidate_check_on_setup_change
    return unless SETUP_FIELDS.any? { |field| will_save_change_to_attribute?(field) }

    self.last_check_status = nil
    self.last_check_message = nil
    self.last_checked_at = nil
  end

  def valid_credentials
    values = credential_values
    allowed = definition&.fetch(:credentials, []) || []
    if credentials_json.to_s.bytesize > 16_384 || (values.keys - allowed).any? || values.values.any? { |value| !value.is_a?(String) || !value.valid_encoding? || value.bytesize > 4096 || value.match?(/[\x00-\x1f\x7f]/) }
      errors.add(:base, 'The connection credentials are unsupported or too long.')
      return
    end
    return if values.empty?

    errors.add(:base, 'Confirm approved dedicated API access before saving credentials.') unless vendor_approved
    errors.add(:base, 'Provide all required API credential fields.') unless allowed.all? { |key| values[key].present? }
    if provider == 'korona'
      errors.add(:base, 'Use the exact HTTPS KORONA API endpoint shown in your API widget.') unless values['api_url'].to_s.bytesize <= 2048 && PaymentProviders::KoronaCheck::API_URL_PATTERN.match?(values['api_url'].to_s)
      errors.add(:base, 'Use a dedicated API username of at most 512 bytes without a colon.') if values['api_username'].to_s.bytesize > 512 || values['api_username'].to_s.include?(':')
      errors.add(:base, 'Use the account UUID from KORONA.') unless values['account_id'].to_s.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
    elsif provider == 'cova'
      errors.add(:base, 'Use the positive Company ID from your Cova onboarding package.') unless values['company_id'].to_s.match?(/\A[1-9][0-9]{0,9}\z/) && values['company_id'].to_i <= 2_147_483_647
    end
  end
end
