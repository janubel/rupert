# frozen_string_literal: true

require 'base64'
require 'digest'

# Append-only accounting evidence. No pruning policy or application delete route.
class ReconciliationDocument < ApplicationRecord
  include TenantScoped
  encrypts :content_base64
  encrypts :metadata_json
  belongs_to :uploaded_by, class_name: 'User', optional: true
  belongs_to :supersedes, class_name: 'ReconciliationDocument', optional: true
  SOURCES = %w[shopify square swipesimple ctrax cash_app authorize_net iris bank other rupert].freeze
  GENERATED_KINDS = %w[daily_archive period_archive close_package cash_forecast].freeze
  KINDS = (%w[register_control gateway_report processor_report bank_statement invoice fee_statement source_export other] + GENERATED_KINDS).freeze
  validates :tenant_id, :filename, :sha256, :fingerprint, :period_from, :period_to, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :kind, inclusion: { in: KINDS }
  before_update { throw :abort }
  before_destroy { throw :abort }

  scope :covering, ->(day) { where('period_from <= ? AND period_to >= ?', day, day) }

  def metadata
    JSON.parse(metadata_json)
  end

  def original_bytes
    bytes = Base64.strict_decode64(content_base64)
    raise 'Retained document checksum mismatch' unless Digest::SHA256.hexdigest(bytes) == sha256 && bytes.bytesize == byte_size

    bytes
  end
end
