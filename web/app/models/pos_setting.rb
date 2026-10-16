# frozen_string_literal: true

class PosSetting < ApplicationRecord
  include TenantScoped
  belongs_to :location
  encrypts :credentials_json
  validates :location_id, uniqueness: { scope: :tenant_id }
  validates :gateway_provider, inclusion: { in: %w[authorize_net nmi] }
  validates :environment, inclusion: { in: %w[sandbox production] }
  validate do
    errors.add(:location, 'must be a C-Trax store in this workspace') unless location&.tenant_id == tenant_id && location.source == 'ctrax'
    errors.add(:base, 'NMI production payments are disabled pending Next Stage confirmation.') if gateway_provider == 'nmi' && environment != 'sandbox'
    allowed = gateway_provider == 'nmi' ? %w[security_key tokenization_key merchant_company] : %w[api_login_id transaction_key]
    if credentials.any? { |key, v| !v.is_a?(String) || !(key == 'merchant_company' ? v.match?(/\A[[:print:]]{1,128}\z/) : v.match?(/\A[[:graph:]]{1,128}\z/)) } || (credentials.keys - allowed).any?
      errors.add(:base, 'Enter supported gateway credentials.')
    end
    errors.add(:base, 'Check this gateway before enabling card charges.') if card_enabled && !verified_at
    errors.add(:gateway_id, 'must be a numeric gateway account ID') if gateway_id.present? && !gateway_id.match?(/\A[1-9][0-9]{0,29}\z/)
    if credentials['api_login_id'].to_s.length > 25 || credentials['transaction_key'].to_s.length > 16
      errors.add(:base, 'Gateway API Login ID or Transaction Key is too long.')
    end
    if persisted? && (will_save_change_to_credentials_json? || will_save_change_to_gateway_id? || will_save_change_to_environment? || will_save_change_to_gateway_provider?) && PosCheckout.where(location_id: location_id, tender: 'card', status: %w[processing unknown]).exists?
      errors.add(:base, 'Resolve outstanding card payments before changing the gateway account or credentials.')
    end
  end
  before_validation do
    if will_save_change_to_credentials_json? || will_save_change_to_gateway_id? || will_save_change_to_environment? || will_save_change_to_gateway_provider?
      self.verified_at = nil
      self.public_client_key = nil
      self.card_enabled = false
    end
  end
  def nmi_sandbox? = gateway_provider == 'nmi' && environment == 'sandbox'

  def payment_fingerprint
    Digest::SHA256.hexdigest([gateway_provider, environment, gateway_id, credentials.sort].to_json)
  end

  def credentials
    value = JSON.parse(credentials_json.presence || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end
end
