# frozen_string_literal: true

require 'base64'
require 'digest'

# An outside export kept byte for byte. Append-only: there is no edit or delete
# path, and the checksum is verified on every read.
class ImportSourceDocument < ApplicationRecord
  include TenantScoped

  encrypts :content_base64

  SOURCES = %w[quickbooks].freeze
  KINDS = %w[chart_of_accounts journal vendors customers trial_balance].freeze

  belongs_to :uploaded_by, class_name: 'User', optional: true
  has_many :batches, class_name: 'ImportBatch', foreign_key: :source_document_id, inverse_of: :source_document, dependent: :restrict_with_exception

  validates :source, inclusion: { in: SOURCES }
  validates :kind, inclusion: { in: KINDS }
  validates :filename, :content_type, :sha256, :content_base64, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }

  before_update { throw :abort }
  before_destroy { throw :abort }

  def original_bytes
    bytes = Base64.strict_decode64(content_base64)
    raise 'Retained document checksum mismatch' unless Digest::SHA256.hexdigest(bytes) == sha256 && bytes.bytesize == byte_size

    bytes
  end
end
