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
    refuse_mirrored_reupload!
    seen = Hash.new(0)
    created = duplicates = 0
    doc = nil
    # One transaction: if nothing new arrives, a newly retained evidence copy is
    # rolled back with it instead of lingering as an empty statement.
    BankStatementLine.transaction do
      doc = ReconciliationEvidence.retain!(bytes: @text, filename: filename, source: 'bank', kind: 'bank_statement',
        from: from.iso8601, to: to.iso8601, metadata: { 'note' => "Statement for #{@label}", 'withdrawals_positive' => @flip }, actor: actor)
      rows.each do |row|
        key = [row.posted_on.iso8601, row.amount_cents, row.description.downcase.squish]
        seen[key] += 1
        fingerprint = Digest::SHA256.hexdigest([Current.tenant_id, @label.downcase, *key, seen[key]].to_json)
        if BankStatementLine.exists?(fingerprint: fingerprint) || !create_line(doc, row, fingerprint)
          duplicates += 1
        else
          created += 1
        end
      end
      raise Error, 'Every line in this file was already imported, so nothing new was retained.' if created.zero? && doc.previously_new_record?
    end
    { document: doc, created: created, duplicates: duplicates, from: from, to: to }
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

  # A concurrent upload of the same lines can win the unique fingerprint index
  # between the existence check and the insert; count that as already seen.
  def create_line(doc, row, fingerprint)
    BankStatementLine.transaction(requires_new: true) do
      BankStatementLine.create!(document_id: doc.id, account_label: @label, line_no: row.line_no, posted_on: row.posted_on,
        description: row.description, amount_cents: row.amount_cents, fingerprint: fingerprint)
    end
    true
  rescue ActiveRecord::RecordNotUnique
    false
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
    raise Error, "Too many rows (limit #{MAX_ROWS})." if table.size > MAX_ROWS

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
