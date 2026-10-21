# frozen_string_literal: true

require 'bigdecimal'

class ReconciliationEvidence
  Error = Class.new(ArgumentError)
  MAX_BYTES = 8 * 1024 * 1024
  AMOUNTS = %w[order_total cash card refunds tips fees deposit].freeze
  # Net totals may be negative; these are entered as positive magnitudes.
  UNSIGNED = %w[refunds tips fees deposit].freeze
  TYPES = { '.csv' => 'text/csv', '.pdf' => 'application/pdf', '.png' => 'image/png',
    '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.json' => 'application/json', '.txt' => 'text/plain' }.freeze

  # Metadata uses strings and integer cents, never floating point or inferred zeros.
  def self.retain!(bytes:, filename:, source:, kind:, from:, to:, metadata: {}, actor: nil, supersedes_id: nil)
    raise Error, 'An active workspace is required.' unless Current.tenant&.status == 'active'
    raise Error, 'Attach a document of 1 byte to 8 MiB.' unless bytes.is_a?(String) && bytes.bytesize.between?(1, MAX_BYTES)
    raise Error, 'Choose a supported source and document kind.' unless ReconciliationDocument::SOURCES.include?(source) && ReconciliationDocument::KINDS.include?(kind)

    first, last = dates(from, to)
    name = File.basename(filename.to_s.tr('\\', '/')).gsub(/[^a-zA-Z0-9._-]/, '_').first(150)
    type = TYPES[File.extname(name).downcase]
    raise Error, 'Use a CSV, PDF, PNG, JPEG, JSON or text document.' unless type
    validate_bytes!(bytes, type)
    raise Error, 'Invalid evidence metadata.' unless metadata.is_a?(Hash) && metadata.to_json.bytesize <= 16_384

    # Canonical serialization keeps exact replays idempotent across callers.
    meta = metadata.deep_stringify_keys.sort.to_h
    if kind == 'register_control'
      raise Error, 'A register control must cover exactly one day and identify its currency.' unless first == last && meta['currency'].to_s.match?(/\A[A-Z]{3}\z/)
      raise Error, 'Register controls require at least one source total.' unless AMOUNTS.any? { |key| meta[key].is_a?(Integer) }
      raise Error, 'Invalid control totals.' unless AMOUNTS.all? { |key| meta[key].nil? || (meta[key].is_a?(Integer) && meta[key].abs < 10**15) }
      raise Error, 'Refunds, fees, tips and deposits must be zero or positive.' if !meta['withdrawn'] && UNSIGNED.any? { |key| meta[key].to_i.negative? }
    end
    sha = Digest::SHA256.hexdigest(bytes.b)
    fingerprint = Digest::SHA256.hexdigest([source, kind, first, last, sha, meta, supersedes_id.presence&.to_i].to_json)
    ReconciliationDocument.transaction do
      # Serialize replay/correction checks with SQLite's writer lock.
      locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      raise Error, 'An active workspace is required.' unless locked == 1
      existing = ReconciliationDocument.find_by(fingerprint: fingerprint)
      return existing if existing

      if supersedes_id.present?
        previous = ReconciliationDocument.find_by(id: supersedes_id)
        unless previous && previous.kind == kind && previous.source == source && previous.period_from == first && previous.period_to == last &&
            identity_context(previous.metadata) == identity_context(meta) &&
            !ReconciliationDocument.exists?(supersedes_id: previous.id)
          raise Error, 'Choose the current document in the same source, period, currency and location to correct.'
        end
      end
      ReconciliationDocument.create!(source: source, kind: kind, period_from: first, period_to: last,
        filename: name, content_type: type, byte_size: bytes.bytesize, content_base64: Base64.strict_encode64(bytes.b),
        sha256: sha, fingerprint: fingerprint, metadata_json: meta.to_json, uploaded_by: actor, supersedes_id: supersedes_id.presence)
    end
  end

  def self.identity_context(metadata)
    %w[currency location_id merchant api_origin report_kind].to_h { |key| [key, metadata[key].presence] }
  end

  def self.dates(from, to)
    raise Error, 'Use dates in YYYY-MM-DD format.' unless [from, to].all? { |date| date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) }
    first, last = [from, to].map { |date| Date.iso8601(date.to_s) }
    raise Error, 'The document period must be ordered and no longer than 366 days.' unless (last - first).between?(0, 365)
    [first, last]
  rescue Date::Error
    raise Error, 'Choose valid calendar dates.'
  end

  # Accepts 1234.56, 1,234.56, $1,234.56, .50 and surrounding spaces; never guesses at ambiguous separators.
  def self.cents(value, metric: nil)
    return nil if value.blank?
    text = value.to_s.strip
    match = text.match(/\A(-)?\$?(\d{1,3}(?:,\d{3})+|\d+)?(?:\.(\d{1,2}))?\z/)
    unless match && (match[2] || match[3]) && match[2].to_s.delete(',').length <= 12
      raise Error, "#{label(metric)}: use commas only between groups of three digits, for example 1,234.56." if text.include?(',')
      raise Error, "#{label(metric)}: enter at most two decimal places." if text.match?(/\.\d{3,}\z/)
      raise Error, "#{label(metric)}: enter an amount like 1234.56, 1,234.56 or $1,234.56 (up to 12 digits; no other symbols or letters)."
    end
    raise Error, "#{label(metric)}: enter a positive amount; refunds, fees, tips and deposits are recorded without a minus sign." if match[1] && UNSIGNED.include?(metric)
    cents = (match[2].to_s.delete(',').to_i * 100) + match[3].to_s.ljust(2, '0').to_i
    match[1] ? -cents : cents
  end

  def self.label(metric)
    metric ? metric.to_s.humanize : 'Amount'
  end

  def self.validate_bytes!(bytes, type)
    valid = case type
    when 'application/pdf' then bytes.b.start_with?('%PDF-')
    when 'image/png' then bytes.b.start_with?("\x89PNG\r\n\x1a\n".b)
    when 'image/jpeg' then bytes.b.start_with?("\xff\xd8\xff".b)
    else bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !bytes.include?("\x00")
    end
    raise Error, 'The file content does not match its supported format.' unless valid
  end
end
