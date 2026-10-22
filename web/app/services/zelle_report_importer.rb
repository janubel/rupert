# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'

# Manual Zelle bank-statement CSV evidence. Zelle has no public merchant API and
# Rupert never signs in to a bank, so this importer only reads a file the
# operator supplies. It writes zelle_exports and zelle_entries and nothing else:
# no Core::Order, ledger, SwipeSimple, customer, payment or stock records.
class ZelleReportImporter
  Error = Class.new(ArgumentError)
  MAX_BYTES = SwipesimpleReportImporter::MAX_BYTES
  MAX_ROWS = SwipesimpleReportImporter::MAX_ROWS
  MAX_FIELD_BYTES = SwipesimpleReportImporter::MAX_FIELD_BYTES
  CONTRACT = 'zelle-bank-csv-v1'
  REQUIRED_HEADERS = ['Date', 'Amount', 'Direction', 'Reference ID'].freeze
  OPTIONAL_HEADERS = %w[Counterparty Memo].freeze
  CONTEXT_KEYS = %w[account_label currency exported_at].freeze
  Prepared = Struct.new(:text, :context, :rows, :fingerprint, :sha256, keyword_init: true) do
    def summary
      credits = rows.select { |row| row[:direction] == 'credit' }
      debits = rows.select { |row| row[:direction] == 'debit' }
      { rows: rows.length, currency: context['currency'], credit_count: credits.length, debit_count: debits.length,
        credit_cents: credits.sum { |row| row[:amount_cents] }, debit_cents: debits.sum { |row| row[:amount_cents] },
        first_posted_on: rows.pluck(:posted_on).min, last_posted_on: rows.pluck(:posted_on).max }
    end
  end

  class << self
    def preview(source, options)
      context = validate_context(options)
      text = source.is_a?(String) ? source.dup : source.read(MAX_BYTES + 1).to_s
      raise Error, 'The export exceeds the 8 MiB limit.' if text.bytesize > MAX_BYTES

      text = text.b.force_encoding(Encoding::UTF_8)
      raise Error, 'The export must be UTF-8 text without null characters.' unless text.valid_encoding? && !text.include?("\x00")

      reader = CSV.new(text.delete_prefix("﻿"), headers: true, field_size_limit: MAX_FIELD_BYTES)
      rows = []
      names = nil
      reader.each.with_index(2) do |row, position|
        raise Error, 'The export exceeds the 10,000-row limit.' if position > MAX_ROWS + 1

        names ||= header_names!(reader.headers)
        fail_row!(position, 'Cell count differs from the headers') unless row.fields.length == names.length
        fail_row!(position, 'A cell is too long or contains control characters') if row.fields.any? do |cell|
          cell && (cell.bytesize > MAX_FIELD_BYTES || cell.match?(/[\x00-\x1f\x7f]/))
        end
        rows << parse_row(names.zip(row.fields.map { |value| value.to_s.strip }).to_h, context, position)
      end
      header_names!(reader.headers) unless names
      raise Error, 'The export contains no records.' if rows.empty?
      raise Error, 'Duplicate bank reference IDs in this export require source review.' unless rows.pluck(:identity).uniq.length == rows.length

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

      ZelleExport.transaction do
        # Tenant writer lock keeps replay and overlap checks atomic across
        # simultaneous imports.
        locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
        raise Error, 'An active workspace is required.' unless locked == 1

        existing = ZelleExport.find_by(fingerprint: prepared.fingerprint)
        return existing if existing

        verify_overlap!(prepared)
        summary = prepared.summary
        receipt = ZelleExport.create!(prepared.context.merge(
          fingerprint: prepared.fingerprint, sha256: prepared.sha256, original_csv: prepared.text, imported_by: actor,
          row_count: prepared.rows.length, first_posted_on: summary[:first_posted_on], last_posted_on: summary[:last_posted_on]))
        prepared.rows.each { |row| receipt.entries.create!(row) }
        receipt
      end
    rescue ActiveRecord::ActiveRecordError
      raise Error, 'The local snapshot could not be saved safely. Nothing was imported.', cause: nil
    end

    private

    def validate_context(options)
      context = options.to_h.stringify_keys.slice(*CONTEXT_KEYS).transform_values { |value| value.to_s.strip }
      label = context['account_label'].to_s
      if label.blank? || label.bytesize > 100 || label.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'Enter a short bank account label (maximum 100 characters). Do not enter a full account number.'
      end
      raise Error, 'Only explicitly confirmed USD exports are supported.' unless context['currency'] == 'USD'

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

    # Header names are matched ignoring case and surrounding space, then
    # canonicalised. Unknown or repeated columns are rejected so a changed bank
    # layout is visible instead of silently misread.
    def header_names!(headers)
      allowed = REQUIRED_HEADERS + OPTIONAL_HEADERS
      names = Array(headers).map { |header| allowed.find { |name| name.casecmp?(header.to_s.strip) } }
      unless names.none?(&:nil?) && names.uniq.length == names.length && (REQUIRED_HEADERS - names).empty?
        raise Error, 'Unsupported CSV headers. Use exactly: Date, Amount, Direction, Reference ID, and optionally Counterparty and Memo.'
      end
      names
    end

    def parse_row(row, context, position)
      reference = row['Reference ID']
      fail_row!(position, 'A bank reference ID is required (maximum 200 characters)') if reference.blank? || reference.bytesize > 200
      direction = row['Direction'].downcase
      fail_row!(position, 'Direction must be credit (money received) or debit (money sent)') unless ZelleEntry::DIRECTIONS.include?(direction)
      identity = Digest::SHA256.hexdigest(JSON.generate([context['account_label'], context['currency'], reference]))
      { identity: identity, bank_reference: reference, counterparty: row['Counterparty'].presence, memo: row['Memo'].presence,
        direction: direction, tender: ZelleEntry::TENDER, verification: 'unverified',
        amount_cents: money!(row['Amount'], position), posted_on: posted_on!(row['Date'], context, position), source_row: position }
    end

    def money!(value, position)
      unless value.to_s.match?(/\A\$?(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)\.[0-9]{2}\z/)
        fail_row!(position, 'Expected a nonnegative dollar amount with two decimals; use the Direction column for sign')
      end
      cents = (BigDecimal(value.delete('$,')) * 100).to_i
      fail_row!(position, 'Amount must be greater than zero') if cents.zero?
      fail_row!(position, 'Amount exceeds the supported limit') if cents > 2_147_483_647
      cents
    end

    def posted_on!(value, context, position)
      date = if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.strptime(value, '%Y-%m-%d')
      elsif value.match?(/\A\d{1,2}\/\d{1,2}\/\d{4}\z/)
        Date.strptime(value, '%m/%d/%Y')
      else
        fail_row!(position, 'Expected a posting date as YYYY-MM-DD or M/D/YYYY')
      end
      fail_row!(position, 'Posting date is after the export time') if date > Time.iso8601(context['exported_at']).to_date + 1
      date
    rescue Date::Error
      fail_row!(position, 'Invalid calendar date')
    end

    # An identity may reappear in later or earlier exports; only two different
    # statements of it at the very same export time are contradictory.
    def verify_overlap!(prepared)
      exported_at = Time.iso8601(prepared.context['exported_at'])
      prepared.rows.each_slice(500) do |rows|
        previous = ZelleEntry.where(identity: rows.pluck(:identity)).includes(:zelle_export).group_by(&:identity)
        rows.each do |row|
          (previous[row[:identity]] || []).each do |old|
            next unless old.zelle_export.exported_at == exported_at

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
