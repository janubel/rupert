# frozen_string_literal: true

require 'csv'
require 'bigdecimal'

# Reads a QuickBooks (Online or Desktop) report or list exported as CSV into
# plain rows. It touches no database and guesses nothing silently: a file it
# cannot read cleanly is refused with the reason, an unreadable row is kept with
# the reason it was rejected, and every assumption it had to make (encoding,
# date order, how lines were grouped into transactions) is returned in `notes`.
#
# QuickBooks documents no fixed CSV layout for its report exports (see
# docs/ops/quickbooks-import.md), so columns are found by header name, titles
# above the header and totals below the data are skipped, and a layout that
# cannot be posted safely (one signed Amount column) is refused.
class QuickbooksCsv
  Error = Class.new(ArgumentError)

  MAX_BYTES = 10 * 1024 * 1024
  MAX_ROWS = 30_000
  YEARS = (1990..2099)

  Row = Struct.new(:row_no, :record_type, :date, :txn_type, :doc_number, :name, :memo, :account, :account_number, :account_type,
    :debit_cents, :credit_cents, :class_name, :location, :txn_key, :raw, :reason, :skipped, keyword_init: true) do
    def rejected? = !reason.nil?
  end
  Result = Struct.new(:kind, :rows, :layout, :notes, :control, :skipped, keyword_init: true)

  ALIASES = {
    date: ['date', 'transaction date', 'trans date', 'txn date'],
    txn_type: ['transaction type', 'type', 'trans type', 'txn type'],
    doc_number: ['num', 'no.', 'no', 'number', 'doc number', 'ref no.', 'ref no', 'ref number', 'doc num'],
    name: %w[name payee],
    memo: ['memo/description', 'memo', 'description', 'line description'],
    account: ['account', 'account name', 'full name'],
    debit: %w[debit debits],
    credit: %w[credit credits],
    amount: ['amount', 'net amount'],
    class_name: %w[class],
    location: %w[location],
    trans_no: ['trans #', 'trans#', 'trans no', 'trans no.', 'transaction id', 'txn id', 'journal no', 'journal no.', 'journal number', 'trans number']
  }.freeze
  LIST_ALIASES = {
    account_name: ['full name', 'account', 'account name', 'name'],
    account_number: ['number', 'account number', 'account #', 'accnt. #', 'accnt #', 'acct. no.', 'account no.', 'account no'],
    account_type: ['type', 'account type'],
    vendor_name: ['vendor', 'vendor name', 'display name', 'name', 'company name', 'company'],
    customer_name: ['customer', 'customer name', 'display name', 'name', 'company name', 'company']
  }.freeze

  # QuickBooks account types, normalised to letters only, to Rupert's five types.
  ACCOUNT_TYPES = {
    'bank' => 'asset', 'accountsreceivable' => 'asset', 'accountsreceivablear' => 'asset', 'othercurrentasset' => 'asset',
    'othercurrentassets' => 'asset', 'fixedasset' => 'asset', 'fixedassets' => 'asset', 'otherasset' => 'asset', 'otherassets' => 'asset',
    'accountspayable' => 'liability', 'accountspayableap' => 'liability', 'creditcard' => 'liability', 'othercurrentliability' => 'liability',
    'othercurrentliabilities' => 'liability', 'longtermliability' => 'liability', 'longtermliabilities' => 'liability',
    'equity' => 'equity', 'income' => 'revenue', 'otherincome' => 'revenue',
    'costofgoodssold' => 'expense', 'expense' => 'expense', 'expenses' => 'expense', 'otherexpense' => 'expense'
  }.freeze

  def self.parse(bytes, kind:)
    new(bytes, kind).parse
  end

  def self.rupert_type(quickbooks_type)
    ACCOUNT_TYPES[quickbooks_type.to_s.downcase.gsub(/[^a-z]/, '')]
  end

  # Exact decimal to integer cents. US number format only; never rounds.
  def self.cents(raw)
    text = raw.to_s.strip
    return nil if text.empty?

    negative = (text.start_with?('(') && text.end_with?(')')) || text.start_with?('-') || text.end_with?('-')
    number = text.delete('()$ ').sub(/\A[-+]/, '').sub(/-\z/, '')
    unless number.match?(/\A(\d{1,3}(,\d{3})+|\d+)(\.\d+)?\z/) || number.match?(/\A\.\d+\z/)
      raise Error, "Could not read the amount “#{raw.to_s.first(30)}”. Use US number format, for example 1,234.56."
    end

    number = number.delete(',')
    raise Error, "The amount “#{raw.to_s.first(30)}” has more than two decimal places." if number.match?(/\.\d{3,}/) && number.split('.').last.sub(/0+\z/, '').length > 2
    raise Error, "The amount “#{raw.to_s.first(30)}” is too large." if number.split('.').first.length > 13

    value = (BigDecimal(number) * 100).to_i
    negative ? -value : value
  end

  def self.date(raw)
    text = raw.to_s.strip
    result = case text
    when %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z} then Date.new(::Regexp.last_match(3).to_i, ::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i)
    when %r{\A(\d{1,2})/(\d{1,2})/(\d{2})\z} then Date.new(2000 + ::Regexp.last_match(3).to_i, ::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i)
    when /\A(\d{4})-(\d{2})-(\d{2})\z/ then Date.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)
    when /\A(\d{1,2})-(\d{1,2})-(\d{4})\z/ then Date.new(::Regexp.last_match(3).to_i, ::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i)
    end
    raise Error, "Could not read the date “#{raw.to_s.first(30)}”. Use MM/DD/YYYY or YYYY-MM-DD." unless result && YEARS.cover?(result.year)

    result
  rescue Date::Error
    raise Error, "“#{raw.to_s.first(30)}” is not a real date. Rupert reads MM/DD/YYYY (month first) or YYYY-MM-DD."
  end

  def initialize(bytes, kind)
    raise Error, "Unknown export kind #{kind.inspect}." unless ImportSourceDocument::KINDS.include?(kind)
    raise Error, 'The file is empty.' if bytes.to_s.empty?
    raise Error, "The file is larger than #{MAX_BYTES / 1024 / 1024} MiB. Export a shorter date range." if bytes.bytesize > MAX_BYTES

    @kind = kind
    @notes = []
    @text = decode(bytes)
  end

  def parse
    table = read_table
    header_at, heads = find_header(table)
    raise Error, "Could not find a header row. #{expected_headers}" unless header_at

    rows, skipped, control = kind == 'journal' ? parse_transactions(table, header_at, heads) : parse_list(table, header_at, heads)
    raise Error, 'No data rows were found below the header.' if rows.empty?
    raise Error, "Too many rows (limit #{MAX_ROWS}). Export a shorter date range." if rows.size > MAX_ROWS

    Result.new(kind: kind, rows: rows, notes: @notes, control: control, skipped: skipped,
      layout: { 'header_row' => header_at + 1, 'columns' => heads.to_h { |key, i| [key.to_s, table[header_at][1][i].to_s.strip] }, 'delimiter' => @delimiter == "\t" ? 'tab' : @delimiter })
  end

  private

  attr_reader :kind

  def decode(bytes)
    raw = bytes.b
    raise Error, 'The file contains binary data. Export the report as CSV, not Excel.' if raw.start_with?("PK\x03\x04".b) || raw.include?("\x00".b) && !raw.start_with?("\xFF\xFE".b, "\xFE\xFF".b)

    text = if raw.start_with?("\xFF\xFE".b) || raw.start_with?("\xFE\xFF".b)
      @notes << 'Read as UTF-16 text.'
      raw.dup.force_encoding('UTF-16').encode('UTF-8')
    else
      utf8 = raw.dup.force_encoding('UTF-8')
      if utf8.valid_encoding?
        utf8
      else
        @notes << 'The file is not UTF-8; it was read as Windows-1252. Check names with accents in the preview.'
        raw.dup.force_encoding('Windows-1252').encode('UTF-8')
      end
    end
    text.sub(/\A﻿/, '').tr("\r", "\n").squeeze("\n").then { |t| t.include?("\n") ? t : "#{t}\n" }.then { |t| restore_quoted_newlines(text, t) }
  rescue EncodingError
    raise Error, 'The file is not readable text. Export the report as CSV.'
  end

  # The line-ending clean-up above must not alter newlines inside quoted cells,
  # so keep the original text when it already parses (CSV copes with CRLF).
  def restore_quoted_newlines(original, _cleaned)
    original.sub(/\A﻿/, '')
  end

  def read_table
    sample = @text.lines.first(40)
    counts = { ',' => 0, ';' => 0, "\t" => 0 }
    sample.each { |line| counts.each_key { |sep| counts[sep] += line.count(sep) } }
    @delimiter = counts.max_by { |_, n| n }.first
    raise Error, 'This looks like a semicolon-delimited export, which usually means decimal commas. Export again with US number format.' if @delimiter == ';'

    csv = CSV.new(@text, col_sep: @delimiter, skip_blanks: false, liberal_parsing: false)
    table = []
    csv.each do |fields|
      table << [csv.lineno, fields]
      raise Error, "Too many rows (limit #{MAX_ROWS}). Export a shorter date range." if table.size > MAX_ROWS + 200
    end
    table
  rescue CSV::MalformedCSVError => e
    raise Error, "The file is not valid CSV (#{e.message.first(80)})."
  end

  def norm(cell) = cell.to_s.unicode_normalize(:nfkc).downcase.squish.delete_suffix(':')

  def find_header(table)
    table.first(40).each_with_index do |(_, fields), index|
      cells = fields.map { |c| norm(c) }
      heads = map_headers(cells)
      return [index, heads] if heads && header_complete?(heads, cells)
    end
    nil
  end

  def map_headers(cells)
    aliases = kind == 'journal' ? ALIASES : list_aliases
    aliases.each_with_object({}) do |(key, names), found|
      index = pick_column(cells, names)
      found[key] = index if index
    end.then { |h| h.empty? ? nil : h }
  end

  def pick_column(cells, names)
    names.each do |name|
      index = cells.index(name)
      return index if index
    end
    nil
  end

  def list_aliases
    case kind
    when 'chart_of_accounts' then LIST_ALIASES.slice(:account_name, :account_number, :account_type)
    when 'vendors' then LIST_ALIASES.slice(:vendor_name)
    when 'customers' then LIST_ALIASES.slice(:customer_name)
    when 'trial_balance' then { account_name: LIST_ALIASES[:account_name], debit: ALIASES[:debit], credit: ALIASES[:credit], account_number: LIST_ALIASES[:account_number] }
    end
  end

  def header_complete?(heads, cells)
    case kind
    when 'journal'
      return false unless heads[:date] && heads[:account]
      return true if heads[:debit] && heads[:credit]

      raise_single_amount! if heads[:amount]
      false
    when 'chart_of_accounts' then heads[:account_name] && heads[:account_type] && cells.size >= 2
    when 'vendors' then heads[:vendor_name] && cells.size >= 1 && vendor_header?(cells)
    when 'customers' then heads[:customer_name] && customer_header?(cells)
    when 'trial_balance' then heads[:account_name] && heads[:debit] && heads[:credit]
    end
  end

  # A bare "Name" column is accepted for contact lists only when the header row
  # has company/contact style siblings, so a data row is not mistaken for it.
  def vendor_header?(cells) = cells.include?('vendor') || cells.include?('vendor name') || cells.include?('display name') || cells.include?('name') && cells.any? { |c| %w[email phone company company\ name].include?(c) }
  def customer_header?(cells) = cells.include?('customer') || cells.include?('customer name') || cells.include?('display name') || cells.include?('name') && cells.any? { |c| %w[email phone company company\ name].include?(c) }

  def raise_single_amount!
    raise Error, 'This export has a single Amount column. QuickBooks shows that amount with the sign that raises or lowers each account, not as a debit or credit, ' \
                 'so Rupert cannot post it safely. Run the Journal report, or customize the report to show separate Debit and Credit columns, and export again.'
  end

  def expected_headers
    {
      'journal' => 'A Journal export needs Date, Account, Debit and Credit columns.',
      'chart_of_accounts' => 'A chart of accounts export needs Account (or Name) and Type columns.',
      'vendors' => 'A vendor list needs a Vendor (or Name or Display Name) column.',
      'customers' => 'A customer list needs a Customer (or Name or Display Name) column.',
      'trial_balance' => 'A trial balance needs Account, Debit and Credit columns.'
    }.fetch(kind)
  end

  def cell(fields, heads, key)
    index = heads[key]
    index ? fields[index].to_s.strip.then { |v| v.empty? ? nil : v } : nil
  end

  def parse_transactions(table, header_at, heads)
    entries = []
    skipped = Hash.new(0)
    control = nil
    header = nil
    table[(header_at + 1)..].each do |row_no, fields|
      next if fields.all? { |f| f.to_s.strip.empty? }

      account = cell(fields, heads, :account)
      debit_raw = cell(fields, heads, :debit)
      credit_raw = cell(fields, heads, :credit)
      first_text = fields.map { |f| f.to_s.strip }.find(&:present?).to_s
      if first_text.match?(/\Atotal\b/i) && [nil, first_text].include?(cell(fields, heads, :date))
        control = { 'debit_cents' => safe_cents(debit_raw), 'credit_cents' => safe_cents(credit_raw) } if debit_raw || credit_raw
        skipped['total rows'] += 1
        next
      end
      if account.nil? && debit_raw.nil? && credit_raw.nil?
        skipped['title, heading or footer rows'] += 1
        next
      end
      raw = heads.to_h { |key, i| [key.to_s, fields[i].to_s.strip.first(300)] }
      raw['extra'] = extra_columns(table[header_at][1], fields, heads)
      row = Row.new(row_no: row_no, record_type: 'transaction_line', raw: raw, account: account&.squish&.first(200))
      date_raw = cell(fields, heads, :date)
      inherited = date_raw.nil?
      raw['inherited_header'] = inherited ? '1' : nil
      trans_no = cell(fields, heads, :trans_no)
      row.txn_key = "t:#{trans_no}" if trans_no

      # The header (date, type, number, name) of a transaction is tracked from every
      # data row, even one that is rejected or has no amount, so the continuation
      # lines under it can never be attached to the transaction above.
      if inherited
        if header.nil? then row.reason = 'A line with no date and no transaction above it.'
        elsif header[:error] then row.reason = "The first line of this transaction could not be read: #{header[:error]}"
        else
          row.date = header[:date]
          row.txn_type = cell(fields, heads, :txn_type) || header[:txn_type]
          row.doc_number = cell(fields, heads, :doc_number) || header[:doc_number]
          row.name = cell(fields, heads, :name) || header[:name]
        end
      else
        header = { txn_type: cell(fields, heads, :txn_type), doc_number: cell(fields, heads, :doc_number), name: cell(fields, heads, :name), date: nil, error: nil }
        begin
          header[:date] = self.class.date(date_raw)
        rescue Error => e
          header[:error] = row.reason = e.message
        end
        row.date = header[:date]
        row.txn_type, row.doc_number, row.name = header.values_at(:txn_type, :doc_number, :name)
      end
      parse_amounts(row, fields, heads, account, debit_raw, credit_raw, skipped) unless row.reason
      entries << row
    end
    assign_groups(entries, heads)
    [entries.reject(&:skipped), skipped, control]
  end

  def parse_amounts(row, fields, heads, account, debit_raw, credit_raw, skipped)
    raise Error, 'An amount with no account.' if account.nil?

    if debit_raw.nil? && credit_raw.nil?
      skipped['rows without an amount'] += 1
      return row.skipped = true
    end
    debit = debit_raw ? self.class.cents(debit_raw) : 0
    credit = credit_raw ? self.class.cents(credit_raw) : 0
    raise Error, 'A negative amount in a Debit or Credit column. Rupert does not reinterpret signs.' if debit.negative? || credit.negative?
    raise Error, 'The line has both a debit and a credit.' if debit.positive? && credit.positive?

    if debit.zero? && credit.zero?
      skipped['zero-amount lines'] += 1
      return row.skipped = true
    end
    row.debit_cents = debit
    row.credit_cents = credit
    row.memo = cell(fields, heads, :memo)&.first(500)
    row.class_name = cell(fields, heads, :class_name)&.first(100)
    row.location = cell(fields, heads, :location)&.first(100)
  rescue Error => e
    row.reason = e.message
  end

  # Gives every row, readable or not, the key of the transaction it belongs to,
  # so a line that could not be read rejects its whole transaction instead of
  # silently leaving a balanced remainder.
  def assign_groups(entries, heads)
    if heads[:trans_no] && entries.all? { |r| r.txn_key.to_s.start_with?('t:') }
      @notes << 'Lines were grouped into transactions by the Trans # column.'
      return
    end

    continuation = entries.any? { |r| r.raw['inherited_header'] == '1' }
    sequence = 0
    last_signature = nil
    entries.each do |row|
      signature = %w[date txn_type doc_number name].map { |key| row.raw[key].to_s }
      start_new = continuation ? row.raw['inherited_header'] != '1' : signature != last_signature
      sequence += 1 if start_new || sequence.zero?
      row.txn_key = "g:#{sequence}"
      last_signature = signature
    end
    @notes << (continuation ? 'Lines with a blank date were treated as part of the transaction above them.' :
      'This export repeats the date on every line and has no Trans #. Consecutive lines with the same date, type, number and name were grouped as one transaction; check the unbalanced list in the preview.')
  end

  def extra_columns(header_fields, fields, heads)
    used = heads.values
    header_fields.each_with_index.filter_map do |head, i|
      next if used.include?(i) || head.to_s.strip.empty? || fields[i].to_s.strip.empty?

      [head.to_s.strip.first(60), fields[i].to_s.strip.first(200)]
    end.first(12).to_h
  end

  def safe_cents(raw)
    raw ? self.class.cents(raw) : nil
  rescue Error
    nil
  end

  def parse_list(table, header_at, heads)
    rows = []
    skipped = Hash.new(0)
    control = nil
    table[(header_at + 1)..].each do |row_no, fields|
      next if fields.all? { |f| f.to_s.strip.empty? }

      first_text = fields.map { |f| f.to_s.strip }.find(&:present?).to_s
      if first_text.match?(/\Atotal\b/i)
        if kind == 'trial_balance'
          control = { 'debit_cents' => safe_cents(cell(fields, heads, :debit)), 'credit_cents' => safe_cents(cell(fields, heads, :credit)) }
        end
        skipped['total rows'] += 1
        next
      end
      name = cell(fields, heads, :account_name) || cell(fields, heads, :vendor_name) || cell(fields, heads, :customer_name)
      if name.nil?
        skipped['title, heading or footer rows'] += 1
        next
      end
      raw = heads.to_h { |key, i| [key.to_s, fields[i].to_s.strip.first(300)] }
      row = Row.new(row_no: row_no, record_type: record_type, account: name.squish.first(200), name: name.squish.first(200), raw: raw)
      begin
        case kind
        when 'chart_of_accounts'
          row.account_number = cell(fields, heads, :account_number)&.first(40)
          row.account_type = cell(fields, heads, :account_type)&.first(60)
          raise Error, 'The account has no type.' unless row.account_type
        when 'trial_balance'
          row.account_number = cell(fields, heads, :account_number)&.first(40)
          debit_raw = cell(fields, heads, :debit)
          credit_raw = cell(fields, heads, :credit)
          debit = debit_raw ? self.class.cents(debit_raw) : 0
          credit = credit_raw ? self.class.cents(credit_raw) : 0
          raise Error, 'A negative amount in a Debit or Credit column. Rupert does not reinterpret signs.' if debit.negative? || credit.negative?
          raise Error, 'The row has both a debit and a credit.' if debit.positive? && credit.positive?

          row.debit_cents = debit
          row.credit_cents = credit
        end
      rescue Error => e
        row.reason = e.message
      end
      rows << row
    end
    [rows, skipped, control]
  end

  def record_type
    { 'chart_of_accounts' => 'account', 'vendors' => 'vendor', 'customers' => 'customer', 'trial_balance' => 'balance' }.fetch(kind)
  end
end
