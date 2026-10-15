# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'uri'

class OwnerChecklist < ApplicationRecord
  include TenantScoped

  MAX_PAYLOAD_BYTES = 256 * 1024
  MAX_SERVICES = 20
  METADATA_FIELDS = %w[name domain purpose owner_name owner_email owner_phone notes].freeze
  SERVICE_FIELDS = %w[name purpose login_url renewal_cadence renewal_on renewal_notes review_cadence next_review_on
    support_name support_email support_phone mfa_status vault_reference notes archived].freeze
  REVIEW_FIELDS = %w[status evidence tested_on reviewer attest_scope catalog_fingerprint catalog_name catalog_scope catalog_status].freeze
  RENEWAL_CADENCES = %w[unspecified one_time monthly quarterly yearly biennial custom].freeze
  REVIEW_CADENCES = %w[unspecified monthly quarterly yearly custom].freeze
  MFA_STATUSES = %w[unknown enabled not_supported].freeze
  FEATURE_STATUSES = %w[not_reviewed pending passed blocked not_required].freeze
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i
  RESERVED_TLDS = %w[localhost local localdomain internal intranet test invalid example onion home lan alt].freeze

  encrypts :payload_json
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  has_many :owner_checklist_events, dependent: :restrict_with_exception
  has_many :events, class_name: 'OwnerChecklistEvent', dependent: :restrict_with_exception
  attr_accessor :writer_checked

  attr_readonly :tenant_id, :created_by_id
  validates :tenant_id, presence: true
  validate :valid_payload
  validate :checked_writer

  def data
    value = JSON.parse(payload_json.presence || '{}', max_nesting: 12)
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  def services
    data['services'].is_a?(Hash) ? data['services'] : {}
  end

  def feature_reviews
    data['feature_reviews'].is_a?(Hash) ? data['feature_reviews'] : {}
  end

  def self.features
    JSON.parse(Rails.root.join('config/product_roadmap.json').read).fetch('features')
  end

  def features
    self.class.features
  end

  def self.catalog_fingerprint(feature)
    Digest::SHA256.hexdigest(JSON.generate(feature.slice('id', 'name', 'scope', 'status')))
  end

  def feature_review(feature)
    feature = features.find { |entry| entry['id'] == feature } if feature.is_a?(String)
    return { 'status' => 'not_reviewed' } unless feature.is_a?(Hash)

    review = feature_reviews.fetch(feature['id'], { 'status' => 'not_reviewed' }).deep_dup
    if %w[passed not_required].include?(review['status']) && review['catalog_fingerprint'] != self.class.catalog_fingerprint(feature)
      review['status'] = 'stale'
    end
    review
  end

  def self.public_domain?(value)
    return false unless value.is_a?(String) && value.ascii_only? && value.bytesize.between?(4, 253)

    labels = value.downcase.split('.', -1)
    return false unless labels.length >= 2 && labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
    return false unless labels.last.match?(/\A(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})\z/)
    return false if RESERVED_TLDS.include?(labels.last) || value.downcase.end_with?('.home.arpa', '.in-addr.arpa', '.ip6.arpa')

    true
  end

  def self.login_url?(value)
    return false unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 2048 &&
      !value.match?(/[\x00-\x20\x7f\\]/) && !value.match?(/%(?:0[0-9a-f]|1[0-9a-f]|20|7f|5c)/i)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.scheme == 'https' && uri.port == 443 && public_domain?(uri.host) &&
      uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def self.valid_login_url?(value)
    login_url?(value)
  end

  def self.calendar_date(value)
    return unless value.is_a?(String) && value.valid_encoding? && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    date = Date.iso8601(value)
    date if date.year.positive?
  rescue ArgumentError
    nil
  end

  private

  def checked_writer
    errors.add(:base, 'Use the checklist writer so every change has encrypted history.') unless writer_checked
  end

  def valid_payload
    unless payload_json.is_a?(String) && payload_json.valid_encoding? && payload_json.bytesize <= MAX_PAYLOAD_BYTES
      errors.add(:base, 'Checklist data must fit within the 256 KiB limit.')
      return
    end
    value = JSON.parse(payload_json, max_nesting: 12)
    unless value.is_a?(Hash) && value.keys.sort == (METADATA_FIELDS + %w[services feature_reviews]).sort
      errors.add(:base, 'Checklist data contains unsupported fields.')
      return
    end
    { 'name' => 160, 'domain' => 253, 'purpose' => 1000, 'owner_name' => 160, 'owner_email' => 254, 'owner_phone' => 80, 'notes' => 2000 }.each do |key, limit|
      validate_text(value[key], key.humanize, limit, required: %w[name domain purpose owner_name].include?(key), multiline: key == 'notes')
    end
    errors.add(:domain, 'must be a public DNS-style domain, without a URL, IP address or local suffix.') unless self.class.public_domain?(value['domain'])
    validate_email(value['owner_email'], 'Owner email')
    validate_services(value['services'])
    validate_reviews(value['feature_reviews'])
  rescue JSON::ParserError
    errors.add(:base, 'Checklist data must be valid JSON.')
  end

  def validate_text(value, label, limit, required: false, multiline: false)
    unless value.is_a?(String) && value.valid_encoding? && value.length <= limit &&
        !value.match?(multiline ? /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ : /[\x00-\x1f\x7f]/)
      errors.add(:base, "#{label} must be valid text within its field limit.")
      return
    end
    errors.add(:base, "#{label} is required.") if required && value.blank?
  end

  def validate_email(value, label)
    return if value.blank?

    errors.add(:base, "#{label} must be a valid email address.") unless value.is_a?(String) && URI::MailTo::EMAIL_REGEXP.match?(value)
  end

  def validate_services(value)
    unless value.is_a?(Hash) && value.length <= MAX_SERVICES
      errors.add(:base, 'Record at most 20 services per checklist.')
      return
    end
    value.each do |id, service|
      unless id.is_a?(String) && UUID.match?(id) && service.is_a?(Hash) && service.keys.sort == SERVICE_FIELDS.sort
        errors.add(:base, 'Service data contains an invalid identity or unsupported field.')
        next
      end
      limits = { 'name' => 160, 'purpose' => 1000, 'login_url' => 2048, 'renewal_notes' => 2000,
        'support_name' => 160, 'support_email' => 254, 'support_phone' => 80, 'vault_reference' => 200, 'notes' => 2000 }
      limits.each do |key, limit|
        validate_text(service[key], "Service #{key.humanize.downcase}", limit, required: %w[name purpose].include?(key),
          multiline: %w[notes renewal_notes].include?(key))
      end
      if service['login_url'].present? && !self.class.login_url?(service['login_url'])
        errors.add(:base, 'Service login URL must use HTTPS on port 443 with a public DNS-style hostname, without credentials, query or fragment.')
      end
      validate_email(service['support_email'], 'Support email')
      errors.add(:base, 'Choose a supported renewal cadence.') unless RENEWAL_CADENCES.include?(service['renewal_cadence'])
      errors.add(:base, 'Choose a supported review cadence.') unless REVIEW_CADENCES.include?(service['review_cadence'])
      errors.add(:base, 'Choose a supported MFA status.') unless MFA_STATUSES.include?(service['mfa_status'])
      %w[renewal_on next_review_on].each do |key|
        validate_text(service[key], 'Service date', 10)
        errors.add(:base, 'Service dates must be real calendar dates in YYYY-MM-DD format.') if service[key].present? && !self.class.calendar_date(service[key])
      end
      errors.add(:base, 'Service archive state must be a boolean.') unless [true, false].include?(service['archived'])
      if service['vault_reference'].is_a?(String) && service['vault_reference'].match?(%r{://})
        errors.add(:base, 'Vault reference must be an item label, not a credential or login link.')
      end
    end
  end

  def validate_reviews(value)
    unless value.is_a?(Hash)
      errors.add(:base, 'Feature reviews must be a collection of catalog feature IDs.')
      return
    end
    value.each do |id, review|
      unless id.is_a?(String) && id.match?(/\AF[0-9]{2,5}\z/) && review.is_a?(Hash) && review.keys.sort == REVIEW_FIELDS.sort
        errors.add(:base, 'Feature review data contains an invalid identity or unsupported field.')
        next
      end
      errors.add(:base, 'Choose a supported feature review status.') unless FEATURE_STATUSES.include?(review['status'])
      validate_text(review['evidence'], 'Feature evidence', 2000, multiline: true)
      validate_text(review['reviewer'], 'Feature reviewer', 254)
      validate_text(review['tested_on'], 'Tested date', 10)
      validate_text(review['catalog_name'], 'Catalog feature name', 1000, required: true)
      validate_text(review['catalog_scope'], 'Catalog feature scope', 10_000, required: true, multiline: true)
      validate_text(review['catalog_status'], 'Catalog feature status', 40, required: true)
      snapshot = { 'id' => id, 'name' => review['catalog_name'], 'scope' => review['catalog_scope'], 'status' => review['catalog_status'] }
      unless review['catalog_fingerprint'].is_a?(String) && review['catalog_fingerprint'] == self.class.catalog_fingerprint(snapshot)
        errors.add(:base, 'Feature review must contain a consistent catalog snapshot.')
      end
      errors.add(:base, 'Feature scope attestation must be a boolean.') unless [true, false].include?(review['attest_scope'])
      date = self.class.calendar_date(review['tested_on'])
      if review['tested_on'].present? && (!date || date > Date.current)
        errors.add(:base, 'Tested date must be a real calendar date no later than today.')
      end
      if review['status'] == 'passed'
        unless review['evidence'].present? && date && date <= Date.current && review['attest_scope'] == true &&
            review['catalog_fingerprint'].to_s.match?(/\A[0-9a-f]{64}\z/) && review['catalog_status'] != 'Planned'
          errors.add(:base, 'Passing requires evidence, a completed test date, current-scope attestation and implemented catalog scope.')
        end
      end
      if review['status'] == 'not_required' && review['evidence'].blank?
        errors.add(:base, 'Explain why this feature is not required.')
      end
    end
  end
end
