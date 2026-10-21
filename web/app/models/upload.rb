# frozen_string_literal: true

require 'base64'
require 'digest'

# One file someone sent to Rupert. The original bytes are retained once, encrypted
# and unchanged (the checksum is verified on every read); everything else on the
# row is the inbox's own bookkeeping. No business record is created from here.
class Upload < ApplicationRecord
  include TenantScoped

  STATUSES = %w[received recognized needs_review imported rejected duplicate].freeze
  ORIGINS = %w[web api drop].freeze
  OPEN_STATUSES = %w[received recognized needs_review].freeze

  encrypts :content_base64
  encrypts :summary_json
  encrypts :params_json

  belongs_to :uploaded_by, class_name: 'User', optional: true
  belongs_to :duplicate_of, class_name: 'Upload', optional: true

  attr_readonly :tenant_id, :filename, :byte_size, :sha256, :content_base64, :origin, :retained

  validates :tenant_id, :filename, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :origin, inclusion: { in: ORIGINS }
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :sha256, format: { with: /\A\h{64}\z/ }, allow_nil: true

  before_destroy { throw :abort }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :open_items, -> { where(status: OPEN_STATUSES) }

  # ActivityLogger labels the subject with this.
  def display_number = filename

  def original_bytes
    raise 'This upload was not retained.' unless retained && content_base64

    bytes = Base64.strict_decode64(content_base64)
    raise 'Retained upload checksum mismatch' unless Digest::SHA256.hexdigest(bytes) == sha256 && bytes.bytesize == byte_size

    bytes
  end

  def candidates
    candidates_json.present? ? JSON.parse(candidates_json) : []
  end

  def params
    params_json.present? ? JSON.parse(params_json) : {}
  end

  def summary
    summary_json.present? ? JSON.parse(summary_json) : {}
  end

  def confidence_ratio = confidence && (confidence / 100.0)

  def open?
    OPEN_STATUSES.include?(status)
  end

  def discarded?
    discarded_at.present?
  end

  def importer
    Uploads::Registry.find(importer_key)
  end

  def dry_run_current?
    dry_run_digest.present? && importer_key.present? && dry_run_digest == Uploads::Workflow.digest_for(self)
  end

  def status_label
    { 'received' => 'Received', 'recognized' => 'Recognized', 'needs_review' => 'Needs review', 'imported' => 'Imported',
      'rejected' => 'Rejected', 'duplicate' => 'Duplicate' }.fetch(status)
  end
end
