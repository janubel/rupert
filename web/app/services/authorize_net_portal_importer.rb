# frozen_string_literal: true

require 'csv'
require 'digest'
require 'bigdecimal'
require 'time'

class AuthorizeNetPortalImporter
  Error = Class.new(ArgumentError)
  MAX_BYTES = 8 * 1024 * 1024
  REQUIRED = ['Transaction ID', 'Transaction Status', 'Settlement Amount', 'Settlement Currency',
    'Settlement Date/Time', 'Authorization Amount', 'Authorization Currency', 'Submit Date/Time',
    'Reference Transaction ID', 'Transaction Type'].freeze

  def self.import!(text:, gateway_id:, kind:, exported_at:)
    raise Error, 'An active workspace is required.' unless Current.tenant&.status == 'active'
    raise Error, 'Confirm the numeric Gateway ID displayed in the merchant portal.' unless gateway_id.to_s.match?(/\A[1-9][0-9]{0,29}\z/)
    raise Error, 'Choose settled or unsettled transactions.' unless %w[settled unsettled].include?(kind)
    raise Error, 'Attach an expanded comma-separated export no larger than 8 MiB.' unless text.is_a?(String) && text.bytesize.between?(1, MAX_BYTES)
    raise Error, 'Export time must include an explicit time-zone offset.' unless exported_at.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    captured = Time.iso8601(exported_at).utc
    raise Error, 'Export time cannot be in the future.' if captured > 5.minutes.from_now
    csv = CSV.parse(text.delete_prefix("\uFEFF"), headers: true, field_size_limit: 4096)
    unless csv.headers.is_a?(Array) && csv.headers.uniq.size == csv.headers.size && (REQUIRED - csv.headers).empty? && csv.size <= 10_000
      raise Error, 'Use Authorize.net Expanded Fields/Comma Separated without changing the headers.'
    end
    rows = csv.map.with_index(2) do |row, position|
      raise Error, 'The export has an invalid row width.' unless row.fields.size == csv.headers.size
      raise Error, 'The export contains an oversized cell or control characters.' if row.fields.compact.any? { |v| v.bytesize > 4096 || v.match?(/[\x00-\x1f\x7f]/) }

      id = row['Transaction ID'].to_s
      raise Error, 'The export contains an invalid transaction ID.' unless id.match?(/\A[1-9][0-9]{0,29}\z/)
      currency = row['Settlement Currency'].to_s
      raise Error, 'The export contains invalid or differing currencies.' unless currency.match?(/\A[A-Z]{3}\z/) && currency == row['Authorization Currency']
      raise Error, 'The export omits transaction status or type.' if row['Transaction Status'].blank? || row['Transaction Type'].blank?

      { 'transaction_id' => id, 'status' => row['Transaction Status'], 'transaction_type' => row['Transaction Type'],
        'currency' => currency, 'settlement_cents' => cents(row['Settlement Amount']),
        'authorization_cents' => cents(row['Authorization Amount']), 'submitted_at' => timestamp(row['Submit Date/Time']),
        'settled_at' => row['Settlement Date/Time'].present? ? timestamp(row['Settlement Date/Time']) : nil,
        'reference_transaction_id' => row['Reference Transaction ID'], 'source_row' => position }
    end
    raise Error, 'The export repeats transaction IDs; review the source.' unless rows.pluck('transaction_id').uniq.size == rows.size

    sha = Digest::SHA256.hexdigest(text.b)
    fingerprint = Digest::SHA256.hexdigest([gateway_id, kind, captured.iso8601(6), sha].to_json)
    AuthorizeNetPortalExport.transaction do
      Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      AuthorizeNetPortalExport.find_by(fingerprint: fingerprint) || AuthorizeNetPortalExport.create!(
        gateway_id: gateway_id, kind: kind, fingerprint: fingerprint, sha256: sha, exported_at: captured,
        original_csv: text, records_json: rows.to_json)
    end
  rescue CSV::MalformedCSVError, EncodingError, Date::Error
    raise Error, 'The native export has an invalid CSV or timestamp format.', cause: nil
  end

  def self.cents(value)
    raise Error, 'The export has an invalid monetary amount.' unless value.to_s.match?(/\A\$?(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)\.[0-9]{2}\z/)

    number = (BigDecimal(value.delete('$,')) * 100).to_i
    raise Error, 'The export amount is too large.' if number > 2_147_483_647

    number
  end

  def self.timestamp(value)
    raise Error, 'The export timestamp must include its native UTC/GMT/EST/EDT zone.' unless value.to_s.match?(/\A\d{1,2}-[A-Za-z]{3}-\d{4} \d{1,2}:\d{2}:\d{2} (?:AM|PM) (?:UTC|GMT|EST|EDT)\z/)

    DateTime.strptime(value, '%d-%b-%Y %I:%M:%S %p %Z').to_time.utc.iso8601
  end
end
