# frozen_string_literal: true

require 'csv'
require 'bigdecimal'
require 'digest'

# Reads a bank-exported CSV into reviewable lines. It guesses nothing silently:
# a file it cannot read cleanly is rejected with the reason, and no line is
# turned into an expense or payment until a person decides. The original file
# is retained byte-for-byte as evidence.
class BankStatementImport
  Error = Class.new(ArgumentError)
  MAX_ROWS = 5_000
  MAX_SPAN_DAYS = 365
  INSERT_SLICE = 500
  DATE_FORMATS = %w[%Y-%m-%d %m/%d/%Y %m/%d/%y %m-%d-%Y].freeze

  Row = Struct.new(:line_no, :posted_on, :description, :amount_cents, keyword_init: true)

  # `withdrawals_positive`: some banks list withdrawals as positive numbers in a
  # single Amount column. The importer cannot tell, so the person says.
  def initialize(bytes:, account_label:, withdrawals_positive: false)
    @text = decode(bytes)
    @label = account_label.to_s.strip
    @flip = withdrawals_positive
    raise Error, 'Name the account in words, for example "Operating checking". Do not enter the account number.' if @label.blank? || @label.length > 60
    raise Error, 'The account name looks like an account number. Use a name instead.' if @label.gsub(/\D/, '').length >= 6
  end

  def rows
    @rows ||= parse
  end

  def import!(filename:, actor:)
    raise Error, 'No transaction rows were found.' if rows.empty?

    from, to = rows.map(&:posted_on).minmax
    if (to - from) > MAX_SPAN_DAYS
      raise Error, "This file covers #{from} to #{to}, more than one year. Split it into files covering one year or less " \
                   "(and no more than #{MAX_ROWS} rows each) and upload each one."
    end
    refuse_mirrored_reupload!
    refuse_locked_periods!
    prepared = fingerprinted_rows
    created = duplicates = 0
    doc = nil
    # One transaction: if nothing new arrives, a newly retained evidence copy is
    # rolled back with it instead of lingering as an empty statement. Lines are
    # inserted in batches so the write lock is held briefly even for 5,000 rows.
    BankStatementLine.transaction do
      doc = ReconciliationEvidence.retain!(bytes: @text, filename: filename, source: 'bank', kind: 'bank_statement',
        from: from.iso8601, to: to.iso8601, metadata: { 'note' => "Statement for #{@label}", 'withdrawals_positive' => @flip }, actor: actor)
      seen = already_imported(prepared.keys)
      fresh = prepared.reject { |fingerprint, _row| seen.include?(fingerprint) }
      created = insert_lines(doc, fresh)
      duplicates = prepared.size - created
      raise Error, 'Every line in this file was already imported, so nothing new was retained.' if created.zero? && doc.previously_new_record?
    end
    { document: doc, created: created, duplicates: duplicates, from: from, to: to }
  rescue ActiveRecord::RecordInvalid => e
    raise Error, "The statement could not be saved: #{e.record.errors.full_messages.to_sentence}."
  end

  def self.parse_amount(raw)
    text = raw.to_s.strip
    return nil if text.empty?

    negative = text.start_with?('(') && text.end_with?(')') || text.start_with?('-') || text.end_with?('-')
    number = text.gsub(/[()$,\s+-]/, '')
    raise Error, "Could not read the amount “#{raw}”." unless number.match?(/\A\d+(\.\d{1,4})?\z/)

    cents = (BigDecimal(number) * 100).round
    negative ? -cents : cents
  end

  def self.parse_date(raw)
    text = raw.to_s.strip
    DATE_FORMATS.each do |format|
      date = Date.strptime(text, format)
      return date if date.year.between?(2000, 2099)
    rescue Date::Error
      next
    end
    raise Error, "Could not read the date “#{raw}”. Use YYYY-MM-DD or MM/DD/YYYY."
  end

  private

  # Identical same-day lines get a running count so each gets its own fingerprint.
  def fingerprinted_rows
    seen = Hash.new(0)
    rows.to_h do |row|
      key = [row.posted_on.iso8601, row.amount_cents, row.description.downcase.squish]
      seen[key] += 1
      [Digest::SHA256.hexdigest([Current.tenant_id, @label.downcase, *key, seen[key]].to_json), row]
    end
  end

  def already_imported(fingerprints)
    fingerprints.each_slice(INSERT_SLICE).flat_map { |slice| BankStatementLine.where(fingerprint: slice).pluck(:fingerprint) }.to_set
  end

  # insert_all skips callbacks, so the tenant and timestamps are set here; the
  # encrypted columns are still encrypted by their attribute types. A concurrent
  # upload of the same lines can win the unique fingerprint index between the
  # existence check and the insert; those rows are skipped and counted as seen.
  def insert_lines(doc, fresh)
    now = Time.current
    fresh.each_slice(INSERT_SLICE).sum do |slice|
      attributes = slice.map do |fingerprint, row|
        { tenant_id: Current.tenant_id, document_id: doc.id, account_label: @label, line_no: row.line_no, posted_on: row.posted_on,
          description: row.description, amount_cents: row.amount_cents, fingerprint: fingerprint, status: 'pending', created_at: now }
      end
      BankStatementLine.insert_all(attributes, unique_by: :idx_bank_lines_fingerprint, returning: [:id]).length
    end
  end

  # One check for the whole file instead of two lock queries per line: a line
  # dated inside a locked month, quarter or year cannot be imported, so the
  # file is refused up front naming the periods.
  def refuse_locked_periods!
    locked = PeriodLock.active_locks.select { |lock| rows.any? { |row| row.posted_on.between?(lock.period_from, lock.period_to) } }
    return if locked.empty?

    count = rows.count { |row| locked.any? { |lock| row.posted_on.between?(lock.period_from, lock.period_to) } }
    raise Error, "#{count} line(s) are dated inside locked periods: #{locked.map(&:label).uniq.join(', ')}. " \
                 'Unlock them on the Books desk, with a reason, or remove those lines from the file before importing.'
  end

  # Re-uploading the same file with the withdrawals setting flipped would mirror
  # every amount, defeat the fingerprints and duplicate the statement.
  def refuse_mirrored_reupload!
    sha = Digest::SHA256.hexdigest(@text.b)
    earlier = ReconciliationDocument.where(kind: 'bank_statement', sha256: sha).select(:id, :metadata_json).to_a
    return unless earlier.any? { |doc| doc.metadata['withdrawals_positive'].present? != @flip }

    raise Error, "This file was already imported with withdrawals #{@flip ? 'as negative numbers' : 'as positive numbers'}. " \
                 'Re-uploading it with the other setting would duplicate every line with the opposite sign.'
  end

  def decode(bytes)
    text = bytes.to_s.dup.force_encoding('UTF-8').sub(/\A﻿/, '')
    raise Error, 'The file is not readable text. Export the statement as CSV.' unless text.valid_encoding?

    text
  end

  # Some banks put account summaries above the real header; find the header row.
  def parse
    lines = @text.lines
    header_at = lines.first(20).index { |l| l.downcase.match?(/date/) && l.downcase.match?(/amount|debit|credit|withdraw|deposit/) }
    raise Error, 'Could not find a header row with a date and an amount (or debit/credit) column.' unless header_at

    # Blank rows are kept (and skipped below) so line numbers match the file.
    table = CSV.parse(lines[header_at..].join, headers: true, skip_blanks: false)
    heads = table.headers.compact.to_h { |h| [h, h.to_s.downcase.strip] }
    pick = ->(pattern) { heads.find { |_, name| name.match?(pattern) }&.first }
    date_col = pick.call(/\A(posting |transaction |post |trans(action)? )?date\z/) || pick.call(/date/)
    desc_col = pick.call(/description|memo|payee|details|name/)
    amount_col = pick.call(/\Aamount\z/)
    debit_col = pick.call(/debit|withdraw|money out|paid out/)
    credit_col = pick.call(/credit|deposit|money in|paid in/)
    raise Error, 'Could not find a description column.' unless desc_col
    raise Error, 'Could not find an amount, or debit and credit, columns.' unless amount_col || (debit_col && credit_col)
    if table.size > MAX_ROWS
      raise Error, "This file has #{table.size} rows; the limit is #{MAX_ROWS}. Split it into smaller files " \
                   "(each covering one year or less, with no more than #{MAX_ROWS} rows) and upload each one."
    end

    result = []
    table.each_with_index do |record, index|
      line_no = header_at + index + 2
      next if record.fields.all?(&:blank?)

      amount = if amount_col
        cents = self.class.parse_amount(record[amount_col])
        cents && (@flip ? -cents : cents)
      else
        out = self.class.parse_amount(record[debit_col])
        into = self.class.parse_amount(record[credit_col])
        out&.nonzero? ? -out.abs : into
      end
      next if amount.nil? || amount.zero?

      result << Row.new(line_no: line_no, posted_on: self.class.parse_date(record[date_col]),
        description: record[desc_col].to_s.squish.first(300).presence || '(no description)', amount_cents: amount)
    rescue Error => e
      raise Error, "Line #{line_no}: #{e.message}"
    end
    result
  rescue CSV::MalformedCSVError => e
    raise Error, "The file is not valid CSV (#{e.message.first(80)})."
  end
end
