# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'

# Native web CSV snapshots only. No vendor HTTP client, canonical order writes,
# stock adjustments, invoice delivery, receipt delivery or payment operations.
class SwipesimpleReportImporter
  Error = Class.new(ArgumentError)
  MAX_BYTES = 8 * 1024 * 1024
  MAX_ROWS = 10_000
  MAX_FIELD_BYTES = 4096
  CONTRACT = 'swipesimple-web-csv-v1'
  TRANSACTION_HEADERS = ['Transaction #', 'Date', 'Type', 'Amount', 'Result', 'Method'].freeze
  TRANSACTION_OPTIONAL = ['Brand', 'Last 4', 'Auth Code', 'Cardholder Name', 'Reference Number',
    'Merchant Account', 'Taken By', 'Tip Amount'].freeze
  INVOICE_HEADERS = ['Invoice Number', 'Customer', 'Date Created', 'Last Sent', 'Due Date', 'Status', 'Amount'].freeze
  CONTEXT_KEYS = %w[kind merchant_account currency source_timezone exported_at invoice_scope].freeze
  Prepared = Struct.new(:text, :context, :rows, :fingerprint, :sha256, keyword_init: true) do
    def summary
      { kind: context['kind'], rows: rows.length, currency: context['currency'],
        statuses: rows.group_by { |row| row[:status] }.transform_values(&:length),
        approved_sale_cents: rows.select { |row| row[:transaction_type] == 'Sale' && row[:status] == 'Approved' }.sum { |row| row[:amount_cents] },
        approved_refund_cents: rows.select { |row| row[:transaction_type] == 'Refund' && row[:status] == 'Approved' }.sum { |row| row[:amount_cents] },
        missing_tip_rows: rows.count { |row| row[:tip_cents].nil? } }
    end
  end

  class << self
    def preview(source, options)
      context = validate_context(options)
      text = source.is_a?(String) ? source.dup : source.read(MAX_BYTES + 1).to_s
      raise Error, 'The export exceeds the 8 MiB limit.' if text.bytesize > MAX_BYTES

      text = text.b.force_encoding(Encoding::UTF_8)
      raise Error, 'The export must be UTF-8 text without null characters.' unless text.valid_encoding? && !text.include?("\x00")

      reader = CSV.new(text.delete_prefix("\uFEFF"), headers: true, field_size_limit: MAX_FIELD_BYTES)
      rows = []
      headers_checked = false
      reader.each.with_index(2) do |row, position|
        raise Error, 'The export exceeds the 10,000-row limit.' if position > MAX_ROWS + 1

        unless headers_checked
          validate_headers(reader.headers, context['kind'])
          headers_checked = true
        end
        fail_row!(position, 'Cell count differs from the headers') unless row.fields.length == reader.headers.length
        fail_row!(position, 'A cell is too long or contains control characters') if row.fields.any? do |cell|
          cell && (cell.bytesize > MAX_FIELD_BYTES || cell.match?(/[\x00-\x1f\x7f]/))
        end
        rows << parse_row(row.to_h.transform_values { |value| value.to_s.strip }, context, position)
      end
      validate_headers(reader.headers, context['kind']) unless headers_checked
      raise Error, 'The export contains no records.' if rows.empty? && context['kind'] == 'transactions'
      raise Error, 'Duplicate source identities in this export require source review.' unless rows.pluck(:identity).uniq.length == rows.length

      sha256 = Digest::SHA256.hexdigest(text.b)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([CONTRACT, context, sha256]))
      Prepared.new(text: text, context: context, rows: rows, fingerprint: fingerprint, sha256: sha256)
    rescue CSV::MalformedCSVError
      raise Error, 'The export is not valid CSV. Check quoting and field lengths.', cause: nil
    end

    def import!(source, options, expected_fingerprint:, actor: nil)
      prepared = preview(source, options)
      raise Error, 'The export or context changed. Preview it again.' unless prepared.fingerprint == expected_fingerprint
      raise Error, 'An active workspace is required.' if Current.tenant_id.blank?

      SwipesimpleExport.transaction do
        # Tenant writer lock works with both PostgreSQL and SQLite, and keeps
        # overlap checks and insertion atomic across simultaneous local imports.
        locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
        raise Error, 'An active workspace is required.' unless locked == 1

        existing = SwipesimpleExport.find_by(fingerprint: prepared.fingerprint)
        return existing if existing

        verify_overlap!(prepared)
        receipt = SwipesimpleExport.create!(prepared.context.except('invoice_scope').merge(
          fingerprint: prepared.fingerprint, sha256: prepared.sha256, original_csv: prepared.text, imported_by: actor))
        prepared.rows.each { |row| receipt.report_rows.create!(row) }
        receipt
      end
    rescue ActiveRecord::ActiveRecordError
      raise Error, 'The local snapshot could not be saved safely. Nothing was imported.', cause: nil
    end

    private

    def validate_context(options)
      context = options.to_h.stringify_keys.slice(*CONTEXT_KEYS).transform_values { |value| value.to_s.strip }
      raise Error, 'Select transactions or invoices.' unless %w[transactions invoices].include?(context['kind'])
      if context['kind'] == 'invoices' && context['invoice_scope'] != 'full'
        raise Error, 'Confirm a full unfiltered invoice export. Invoice numbers are not unique source IDs.'
      end
      context['invoice_scope'] = context['kind'] == 'invoices' ? 'full' : ''
      account = context['merchant_account'].to_s
      raise Error, 'Enter the exact source merchant account (maximum 200 characters).' if account.blank? || account.bytesize > 200 || account.match?(/[\x00-\x1f\x7f]/)
      raise Error, 'Only explicitly confirmed USD exports are supported.' unless context['currency'] == 'USD'

      begin
        TZInfo::Timezone.get(context['source_timezone'].to_s)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise Error, 'Choose the IANA time zone used by the export, such as America/New_York.', cause: nil
      end
      time = context['exported_at'].to_s
      raise Error, 'Export time must include seconds and an explicit UTC offset.' unless SwipesimpleImporter::TIMESTAMP_PATTERN.match?(time) && !time.end_with?('-00:00')

      begin
        parsed = DateTime.iso8601(time)
        raise ArgumentError if parsed.offset.abs > Rational(14, 24)
        captured = Time.iso8601(time)
        raise ArgumentError if captured > 5.minutes.from_now
        context['exported_at'] = captured.utc.iso8601(6)
      rescue ArgumentError
        raise Error, 'Export time must be valid and cannot be in the future.', cause: nil
      end
      context
    end

    def validate_headers(headers, kind)
      required = kind == 'transactions' ? TRANSACTION_HEADERS : INVOICE_HEADERS
      allowed = kind == 'transactions' ? required + TRANSACTION_OPTIONAL : required
      unless headers.is_a?(Array) && headers.uniq.length == headers.length && (required - headers).empty? && (headers - allowed).empty?
        raise Error, 'Unsupported native CSV headers. Export Transactions or Invoices from SwipeSimple Web without renaming columns.'
      end
    end

    def parse_row(row, context, position)
      if context['kind'] == 'transactions'
        if row.key?('Merchant Account') && row['Merchant Account'] != context['merchant_account']
          fail_row!(position, 'Merchant Account differs from the confirmed account; export one account at a time')
        end
        number = identifier!(row['Transaction #'], position)
        type = row['Type']
        status = row['Result']
        fail_row!(position, 'Unknown transaction type') unless %w[Sale Refund].include?(type)
        fail_row!(position, 'Unknown payment result') unless %w[Approved Declined Voided Errored Canceled].include?(status)
        method = row['Method']
        tender = if method == 'Cash'
          'cash'
        elsif %w[Visa Mastercard MasterCard Amex Discover American\ Express].include?(row['Brand']) || %w[Swiped Dipped Tapped Keyed].include?(method)
          'card'
        else
          'unknown'
        end
        amount = money!(row['Amount'], position)
        tip = row['Tip Amount'].present? ? money!(row['Tip Amount'], position) : nil
        fail_row!(position, 'Tip exceeds the processed amount') if tip && tip > amount
        values = { source_number: number, transaction_type: type, status: status, tender: tender,
          amount_cents: amount, tip_cents: tip, occurred_at: local_time!(row['Date'], context, position),
          reference_number: row['Reference Number'].presence }
      else
        number = identifier!(row['Invoice Number'], position)
        status = row['Status']
        unless ['draft', 'unpaid', 'paid', 'marked as paid', 'past due', 'delivery failed', 'voided', 'void'].include?(status)
          fail_row!(position, 'Unknown invoice status')
        end
        values = { source_number: number, status: status, amount_cents: money!(row['Amount'], position),
          occurred_at: local_time!(row['Date Created'], context, position),
          last_sent_at: row['Last Sent'].present? ? local_time!(row['Last Sent'], context, position) : nil,
          due_on: row['Due Date'].present? ? local_date!(row['Due Date'], position) : nil }
      end
      # Invoice numbers are demonstrably non-unique in merchant exports. Row
      # position identifies evidence within a complete snapshot, never an invoice
      # across snapshots. No synthetic invoice IDs are exposed as vendor IDs.
      suffix = context['kind'] == 'invoices' ? position : values[:transaction_type]
      identity = Digest::SHA256.hexdigest(JSON.generate([context['merchant_account'], context['currency'], context['kind'], number, suffix]))
      values.merge(identity: identity, source_row: position)
    end

    def identifier!(value, position)
      fail_row!(position, 'A source number is required (maximum 200 characters)') if value.blank? || value.bytesize > 200
      value
    end

    def money!(value, position)
      unless value.to_s.match?(/\A\$?(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)\.[0-9]{2}\z/)
        fail_row!(position, 'Expected a nonnegative dollar amount with two decimals')
      end
      cents = (BigDecimal(value.delete('$,')) * 100).to_i
      fail_row!(position, 'Amount exceeds the supported limit') if cents > 2_147_483_647
      cents
    end

    def local_time!(value, context, position)
      fail_row!(position, 'Expected the native M/D/YYYY h:mm AM/PM timestamp') unless value.match?(/\A\d{1,2}\/\d{1,2}\/\d{4} \d{1,2}:\d{2} (?:AM|PM)\z/)
      parsed = DateTime.strptime(value, '%m/%d/%Y %I:%M %p')
      zone = TZInfo::Timezone.get(context['source_timezone'])
      periods = zone.periods_for_local(parsed)
      fail_row!(position, 'Timestamp is ambiguous or nonexistent in the confirmed time zone; obtain source clarification') unless periods.one?
      Time.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute) - periods.first.observed_utc_offset
    rescue Date::Error, ArgumentError
      fail_row!(position, 'Invalid local timestamp')
    end

    def local_date!(value, position)
      fail_row!(position, 'Expected the native M/D/YYYY date') unless value.match?(/\A\d{1,2}\/\d{1,2}\/\d{4}\z/)
      Date.strptime(value, '%m/%d/%Y')
    rescue Date::Error
      fail_row!(position, 'Invalid calendar date')
    end

    def verify_overlap!(prepared)
      scope = SwipesimpleExport.where(merchant_account: prepared.context['merchant_account'],
        currency: prepared.context['currency'], kind: prepared.context['kind'])
      if scope.where.not(source_timezone: prepared.context['source_timezone']).exists?
        raise Error, 'An existing account has a different source time zone. Review the source context.'
      end
      if prepared.context['kind'] == 'invoices' && SwipesimpleExport.where(
        merchant_account: prepared.context['merchant_account'], currency: prepared.context['currency'],
        kind: 'invoices', exported_at: prepared.context['exported_at']).exists?
        raise Error, 'A different full invoice snapshot already exists at this export time.'
      end
      prepared.rows.each_slice(500) do |rows|
        previous = SwipesimpleReportRow.where(identity: rows.pluck(:identity)).includes(:swipesimple_export).to_a.group_by(&:identity)
        rows.each do |row|
          (previous[row[:identity]] || []).each do |old|
            context = old.swipesimple_export
            if context.source_timezone != prepared.context['source_timezone']
              raise Error, 'An existing identity has a different source time zone. Review the source context.'
            end
            # Different states are allowed in explicitly later/earlier snapshots.
            # Equal as-of times cannot claim conflicting evidence.
            next unless context.exported_at == Time.iso8601(prepared.context['exported_at'])
            comparable = row.except(:source_row).stringify_keys
            unless comparable.all? { |key, value| old.public_send(key) == value }
              raise Error, 'Conflicting observations at the same export time. Nothing was imported.'
            end
          end
        end
      end
    end

    def fail_row!(position, reason)
      raise Error, "Row #{position}: #{reason}."
    end
  end
end
