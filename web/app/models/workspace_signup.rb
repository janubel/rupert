# frozen_string_literal: true

# Platform admission records, deliberately outside TenantScoped. Reading them
# is restricted to the platform controller; applicants receive no lookup URL.
class WorkspaceSignup < ApplicationRecord
  REFERRAL_DOMAIN = 'herbalhealershcb.com'
  CONSUMER_DOMAINS = %w[gmail.com googlemail.com yahoo.com yahoo.co.uk outlook.com hotmail.com live.com msn.com icloud.com me.com mac.com aol.com proton.me protonmail.com pm.me mail.com gmx.com gmx.net yandex.com zoho.com].freeze
  RESERVED_SUBDOMAINS = %w[www rupert admin administrator api app auth assets billing dashboard help login logout mail platform root security setup signup static status support system test].freeze
  PUBLIC_DOMAIN = /\A(?=.{4,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
  LOCAL_SUFFIXES = %w[localhost local internal invalid test example onion].freeze

  belongs_to :tenant, optional: true
  belongs_to :reviewer, class_name: 'User', optional: true
  has_many :events, class_name: 'WorkspaceSignupEvent', dependent: :restrict_with_exception
  attr_accessor :writer_checked

  before_validation :normalize_fields
  validates :email, presence: true, length: { maximum: 254 }, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :google_subject, presence: true, length: { maximum: 255 }, uniqueness: true
  validates :applicant_name, :workspace_name, presence: true, length: { maximum: 160 }
  validates :status, inclusion: { in: %w[pending approved rejected] }
  validates :referral_domain, inclusion: { in: [REFERRAL_DOMAIN] }
  validates :requested_subdomain, presence: true, length: { in: 2..63 },
    format: { with: /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])\z/ },
    exclusion: { in: RESERVED_SUBDOMAINS }
  validate :private_domain
  validate :controlled_write

  def self.private_domain?(value)
    value.is_a?(String) && value.valid_encoding? && PUBLIC_DOMAIN.match?(value) &&
      !CONSUMER_DOMAINS.include?(value) && !LOCAL_SUFFIXES.include?(value.split('.').last)
  end

  def self.intent(attributes)
    value = attributes.to_h.stringify_keys.slice('workspace_name', 'requested_subdomain', 'domain')
    value.transform_values { |entry| entry.is_a?(String) ? entry.strip : '' }.tap do |fields|
      fields['domain'] = fields['domain'].to_s.downcase
      fields['requested_subdomain'] = fields['requested_subdomain'].to_s.downcase
    end
  end

  def validate_availability
    errors.add(:email, 'already has a Rupert account; sign in instead') if User.exists?(email: email)
    errors.add(:requested_subdomain, 'is already assigned') if Tenant.exists?(subdomain: requested_subdomain)
    errors.add(:domain, 'is already assigned to a workspace') if OauthAllowedDomain.unscoped.exists?(domain: domain)
    errors.empty?
  end

  private

  def normalize_fields
    %i[email domain requested_subdomain].each { |field| self[field] = self[field].to_s.strip.downcase }
    %i[applicant_name workspace_name google_subject].each { |field| self[field] = self[field].to_s.strip }
  end

  def private_domain
    errors.add(:domain, 'must be a private company email domain such as company.com') unless self.class.private_domain?(domain)
    errors.add(:email, 'must match the company domain') unless email.to_s.split('@').last == domain
  end

  def controlled_write
    errors.add(:base, 'Use the verified signup or platform review service.') unless writer_checked
  end
end
