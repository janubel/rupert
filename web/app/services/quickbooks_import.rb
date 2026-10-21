# frozen_string_literal: true

require 'digest'
require 'base64'

# Retains a QuickBooks CSV byte for byte, parses it with QuickbooksCsv and
# stages the result as an ImportBatch for a person to review. Nothing here
# touches the books: no account, vendor, customer or journal entry is created.
# Approval and reversal live in QuickbooksPosting.
#
# Re-uploading the same file returns the batch it already made. An overlapping
# export of the same period stages its transactions as duplicates of the ones
# already staged or posted, matched by a content fingerprint, never by Trans #.
class QuickbooksImport
  Error = Class.new(ArgumentError)

  SAMPLE_LIMIT = 50
  TYPES = { '.csv' => 'text/csv', '.txt' => 'text/plain' }.freeze

  Outcome = Struct.new(:batch, :created, keyword_init: true)

  def self.fold(value) = value.to_s.unicode_normalize(:nfkc).squish.downcase

  def self.stage!(bytes:, kind:, filename:, actor:, as_of: nil)
    new(bytes: bytes, kind: kind, filename: filename, actor: actor, as_of: as_of).stage!
  end

  def initialize(bytes:, kind:, filename:, actor:, as_of: nil)
    @bytes = bytes.to_s.b
    @kind = kind.to_s
    @filename = File.basename(filename.to_s.tr('\\', '/')).gsub(/[^a-zA-Z0-9._-]/, '_').first(150)
    @actor = actor
    @as_of = as_of
  end

  def stage!
    raise Error, 'An active workspace is required.' unless Current.tenant&.status == 'active'
    raise Error, 'Choose what kind of QuickBooks export this is.' unless ImportSourceDocument::KINDS.include?(@kind)
    raise Error, 'Upload a CSV file. Excel files (.xlsx) are not read: in QuickBooks use Export as CSV, or open the Excel file and Save As CSV.' unless TYPES.key?(File.extname(@filename).downcase)

    as_of = parse_as_of
    parsed = parse
    sha = Digest::SHA256.hexdigest(@bytes)
    ImportBatch.transaction do
      # Serialize with SQLite's writer lock so two uploads of one file cannot both stage.
      Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      doc = ImportSourceDocument.find_by(source: 'quickbooks', sha256: sha) || retain(sha)
      existing = ImportBatch.where(source_document_id: doc.id, kind: @kind, as_of: as_of, status: %w[staged approved]).first
      return Outcome.new(batch: existing, created: false) if existing

      batch = build(doc, parsed, as_of)
      Outcome.new(batch: batch, created: true)
    end
  end

  private

  def parse_as_of
    return nil unless @kind == 'trial_balance'

    date = @as_of.to_s.strip
    raise Error, 'Enter the “as of” date of the trial balance (YYYY-MM-DD).' unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(date)
  rescue Date::Error
    raise Error, 'Enter a real “as of” date (YYYY-MM-DD).'
  end

  def parse
    QuickbooksCsv.parse(@bytes, kind: @kind)
  rescue QuickbooksCsv::Error => e
    raise Error, e.message
  end

  def retain(sha)
    ImportSourceDocument.create!(source: 'quickbooks', kind: @kind, filename: @filename, content_type: TYPES.fetch(File.extname(@filename).downcase),
      byte_size: @bytes.bytesize, sha256: sha, content_base64: Base64.strict_encode64(@bytes), uploaded_by: @actor)
  end

  def build(doc, parsed, as_of)
    batch = ImportBatch.create!(source: 'quickbooks', kind: @kind, source_document_id: doc.id, filename: @filename, as_of: as_of,
      summary_json: '{}', created_by_id: @actor&.id, created_by_name: @actor&.display_name || @actor&.email)
    stats = @kind == 'journal' ? stage_transactions(batch, parsed) : stage_list(batch, parsed)
    register_mappings(batch, parsed)
    dates = parsed.rows.reject(&:rejected?).filter_map(&:date)
    batch.update!(
      date_from: dates.min, date_to: dates.max, row_count: parsed.rows.size, transaction_count: stats[:transactions],
      accepted_count: stats[:accepted], duplicate_count: stats[:duplicates], rejected_count: stats[:rejected],
      summary_json: summary(parsed, stats).to_json
    )
    batch
  end

  # --- journal -------------------------------------------------------------

  def stage_transactions(batch, parsed)
    seen = Hash.new(0)
    drafts = []
    loose = []
    parsed.rows.group_by(&:txn_key).each do |key, rows|
      good, bad = rows.partition { |row| !row.rejected? }
      if good.empty?
        loose.concat(bad)
      else
        drafts << draft_for(key, good, seen, bad)
      end
    end
    mark_duplicates(drafts)
    mark_resemblances(drafts)

    transactions = insert_transactions(batch, drafts)
    rows = []
    drafts.each do |draft|
      txn_id = transactions[draft[:key]]
      draft[:lines].each_with_index do |line, index|
        rows << line_attrs(batch, line, transaction_id: txn_id, fingerprint: draft[:line_fingerprints][index], status: line_status(draft), reason: draft[:reason])
      end
      draft[:bad_lines].each { |line| rows << rejected_line_attrs(batch, line, txn_id) }
    end
    loose.each { |line| rows << rejected_line_attrs(batch, line, nil) }
    insert_lines(rows)
    { transactions: drafts.size, accepted: drafts.select { |d| d[:status] == 'staged' }.sum { |d| d[:lines].size },
      duplicates: drafts.select { |d| d[:status] == 'duplicate' }.sum { |d| d[:lines].size },
      rejected: rows.count { |r| r[:status] == 'rejected' }, drafts: drafts }
  end

  def rejected_line_attrs(batch, line, transaction_id)
    line_attrs(batch, line, transaction_id: transaction_id, fingerprint: Digest::SHA256.hexdigest([batch.id, line.row_no, 'rejected'].to_json), status: 'rejected', reason: line.reason)
  end

  def draft_for(key, lines, seen, bad)
    first = lines.first
    debit = lines.sum(&:debit_cents)
    credit = lines.sum(&:credit_cents)
    line_sigs = lines.map { |l| [QuickbooksImport.fold(l.account), l.debit_cents, l.credit_cents, QuickbooksImport.fold(l.memo), QuickbooksImport.fold(l.class_name), QuickbooksImport.fold(l.location)] }
    reason = if bad.any? then "The transaction contains a line that could not be read (row #{bad.first.row_no}); none of it was imported."
    elsif lines.size < 2 then 'A transaction needs at least two lines; this one has one.'
    elsif debit != credit then "Out of balance: debits #{cents_text(debit)} and credits #{cents_text(credit)} differ by #{cents_text((debit - credit).abs)}."
    elsif lines.map(&:date).uniq.size > 1 then 'Lines of one Trans # have different dates.'
    end
    base = Digest::SHA256.hexdigest([Current.tenant_id, 'quickbooks', 'journal', first.date.iso8601, QuickbooksImport.fold(first.txn_type),
      QuickbooksImport.fold(first.doc_number), QuickbooksImport.fold(first.name), line_sigs.sort].to_json)
    # Only transactions that can be imported count as occurrences, so a rejected
    # look-alike cannot shift the fingerprint of a good one.
    seen[base] += 1 unless reason
    fingerprint = seen[base] <= 1 ? base : Digest::SHA256.hexdigest([base, seen[base]].to_json)
    per_line = Hash.new(0)
    line_fps = line_sigs.map do |sig|
      per_line[sig] += 1
      Digest::SHA256.hexdigest([fingerprint, sig, per_line[sig]].to_json)
    end
    { key: key, lines: lines, bad_lines: bad, debit: debit, credit: credit, fingerprint: fingerprint, line_fingerprints: line_fps, date: first.date, txn_type: first.txn_type,
      doc_number: first.doc_number, name: first.name, reason: reason, status: reason ? 'rejected' : 'staged', duplicate_of: nil }
  end

  def mark_duplicates(drafts)
    candidates = drafts.select { |d| d[:status] == 'staged' }
    live = {}
    candidates.map { |d| d[:fingerprint] }.each_slice(500) do |slice|
      ImportTransaction.where(status: %w[staged posted], fingerprint: slice).pluck(:fingerprint, :id, :batch_id).each { |fp, id, batch_id| live[fp] = [id, batch_id] }
    end
    candidates.each do |draft|
      found = live[draft[:fingerprint]] or next
      draft[:status] = 'duplicate'
      draft[:duplicate_of] = found
      draft[:reason] = "Same transaction as one already imported in batch ##{found[1]}."
    end
  end

  # Same date, type, number and total as something already imported, but with
  # different content (for example an edited memo). Held for a person to decide.
  def mark_resemblances(drafts)
    candidates = drafts.select { |d| d[:status] == 'staged' && d[:doc_number].present? }
    return if candidates.empty?

    known = Hash.new { |hash, key| hash[key] = [] }
    candidates.map { |d| d[:doc_number] }.uniq.each_slice(500) do |slice|
      ImportTransaction.where(status: %w[staged posted], doc_number: slice).pluck(:txn_date, :doc_number, :debit_cents, :txn_type, :batch_id)
        .each { |date, num, debit, type, batch_id| known[[date, num, debit]] << [type, batch_id] }
    end
    candidates.each do |draft|
      match = known[[draft[:date], draft[:doc_number], draft[:debit]]].find { |type, _| QuickbooksImport.fold(type) == QuickbooksImport.fold(draft[:txn_type]) }
      draft[:reason] = "Resembles a transaction already imported in batch ##{match[1]} (same date, type, number and total) but its lines differ." if match
    end
  end

  def line_status(draft)
    { 'rejected' => 'rejected', 'duplicate' => 'duplicate' }.fetch(draft[:status], 'staged')
  end

  def insert_transactions(batch, drafts)
    now = Time.current
    rows = drafts.map do |d|
      { tenant_id: Current.tenant_id, batch_id: batch.id, txn_key: d[:key], txn_date: d[:date], txn_type: d[:txn_type]&.first(60), doc_number: d[:doc_number]&.first(60),
        name: encrypt(ImportTransaction, :name, d[:name]), line_count: d[:lines].size, debit_cents: d[:debit], credit_cents: d[:credit],
        fingerprint: d[:fingerprint], status: d[:status], reason: d[:reason], created_at: now, updated_at: now }
    end
    ids = {}
    rows.each_slice(500) do |slice|
      ImportTransaction.insert_all(slice, returning: %w[id txn_key]).each { |row| ids[row['txn_key']] = row['id'] }
    end
    raise Error, 'The transactions could not all be saved. Nothing was imported; try again.' unless ids.size == rows.size

    ids
  end

  def line_attrs(batch, line, transaction_id:, fingerprint:, status:, reason:)
    now = Time.current
    { tenant_id: Current.tenant_id, batch_id: batch.id, transaction_id: transaction_id, row_no: line.row_no, record_type: line.record_type,
      fingerprint: fingerprint, status: status, reason: reason, txn_date: line.date, txn_type: line.txn_type&.first(60), doc_number: line.doc_number&.first(60),
      name: encrypt(ImportLine, :name, line.name), memo: encrypt(ImportLine, :memo, line.memo), account_name: line.account&.first(200),
      account_number: line.account_number, account_type: line.account_type, class_name: line.class_name, location_name: line.location,
      debit_cents: line.debit_cents.to_i, credit_cents: line.credit_cents.to_i, raw_json: encrypt(ImportLine, :raw_json, line.raw.to_json),
      created_at: now, updated_at: now }
  end

  def insert_lines(rows)
    saved = 0
    rows.each_slice(500) { |slice| saved += ImportLine.insert_all(slice, returning: %w[id]).rows.size }
    raise Error, 'The lines could not all be saved. Nothing was imported; try again.' unless saved == rows.size
  end

  # insert_all bypasses attribute encryption, so encrypt explicitly.
  def encrypt(model, attribute, value)
    return nil if value.nil?

    model.type_for_attribute(attribute.to_s).serialize(value)
  end

  # --- lists and trial balance --------------------------------------------

  def stage_list(batch, parsed)
    seen = {}
    rows = []
    live = live_list_fingerprints
    stats = { transactions: 0, accepted: 0, duplicates: 0, rejected: 0 }
    parsed.rows.each do |line|
      key = ImportEntityMapping.key_for(line.account)
      fingerprint = Digest::SHA256.hexdigest([Current.tenant_id, 'quickbooks', @kind, batch.as_of&.iso8601, key, line.debit_cents.to_i, line.credit_cents.to_i].to_json)
      status, reason = if line.rejected? then ['rejected', line.reason]
      elsif seen[fingerprint] then ['duplicate', 'Listed more than once in this file.']
      elsif live.include?(fingerprint) then ['duplicate', 'Already imported from an earlier file.']
      else ['staged', nil]
      end
      if status == 'staged' then seen[fingerprint] = true
      else fingerprint = Digest::SHA256.hexdigest([batch.id, line.row_no, 'unused'].to_json)
      end
      stats[{ 'staged' => :accepted, 'duplicate' => :duplicates, 'rejected' => :rejected }.fetch(status)] += 1
      rows << line_attrs(batch, line, transaction_id: nil, fingerprint: fingerprint, status: status, reason: reason)
    end
    insert_lines(rows)
    stats
  end

  def live_list_fingerprints
    ImportLine.where(status: %w[staged posted], record_type: %w[account vendor customer balance]).pluck(:fingerprint).to_set
  end

  # --- mappings ------------------------------------------------------------

  def register_mappings(batch, parsed)
    seen = {}
    parsed.rows.reject(&:rejected?).each do |row|
      entity_type = { 'transaction_line' => 'account', 'balance' => 'account', 'account' => 'account', 'vendor' => 'vendor', 'customer' => 'customer' }[row.record_type]
      next if entity_type.nil? || row.account.blank?

      key = [entity_type, ImportEntityMapping.key_for(row.account)]
      # One lookup per distinct name; a chart row carries the number and type, so it wins over a bare journal line.
      next if seen[key] && row.record_type != 'account'

      seen[key] = true
      register(batch, entity_type, row.account, row.account_number, row.account_type)
    end
  end

  def register(batch, entity_type, name, number, type)
    return if name.blank?

    key = ImportEntityMapping.key_for(name)
    mapping = ImportEntityMapping.find_or_initialize_by(source: 'quickbooks', entity_type: entity_type, source_key: key)
    mapping.source_name = name.squish.first(200) if mapping.new_record?
    mapping.first_batch_id ||= batch.id
    mapping.source_number ||= number
    mapping.source_type ||= type
    mapping.proposed_type ||= QuickbooksCsv.rupert_type(type) if entity_type == 'account' && type
    mapping.save! if mapping.changed?
  end

  # --- summary -------------------------------------------------------------

  def summary(parsed, stats)
    accepted = parsed.rows.reject(&:rejected?)
    # What would actually be imported: lines of staged transactions only.
    importable = stats[:drafts] ? stats[:drafts].select { |d| d[:status] == 'staged' }.flat_map { |d| d[:lines] } : accepted
    by_account = importable.group_by(&:account).transform_values do |lines|
      { 'debit_cents' => lines.sum { |l| l.debit_cents.to_i }, 'credit_cents' => lines.sum { |l| l.credit_cents.to_i }, 'lines' => lines.size }
    end
    out = {
      'layout' => parsed.layout, 'notes' => parsed.notes, 'skipped' => parsed.skipped,
      'control' => parsed.control,
      'totals_by_account' => by_account.sort_by { |name, _| name.to_s }.first(500).to_h,
      'accounts_total' => by_account.size,
      'rejected_samples' => parsed.rows.select(&:rejected?).first(SAMPLE_LIMIT).map { |r| { 'row' => r.row_no, 'reason' => r.reason } },
      'date_assumption' => 'Dates are read month first (MM/DD/YYYY) unless written YYYY-MM-DD.'
    }
    if stats[:drafts]
      drafts = stats[:drafts]
      out['unbalanced'] = drafts.select { |d| d[:status] == 'rejected' }.first(SAMPLE_LIMIT).map do |d|
        { 'date' => d[:date].iso8601, 'type' => d[:txn_type], 'number' => d[:doc_number], 'debit_cents' => d[:debit], 'credit_cents' => d[:credit], 'reason' => d[:reason] }
      end
      out['unbalanced_total'] = drafts.count { |d| d[:status] == 'rejected' }
      out['duplicate_transactions'] = drafts.count { |d| d[:status] == 'duplicate' }
      out['resembling_transactions'] = drafts.count { |d| d[:status] == 'staged' && d[:reason] }
      out['transaction_types'] = drafts.group_by { |d| d[:txn_type].to_s.presence || '(none)' }.transform_values(&:size)
      if parsed.control&.values_at('debit_cents', 'credit_cents')&.all?
        file_debit = accepted.sum { |l| l.debit_cents.to_i }
        file_credit = accepted.sum { |l| l.credit_cents.to_i }
        out['control_matches'] = parsed.control['debit_cents'] == file_debit && parsed.control['credit_cents'] == file_credit
      end
    end
    out
  end

  # Integer cents to a decimal string without floating point.
  def cents_text(cents)
    whole, fraction = cents.abs.divmod(100)
    "#{'-' if cents.negative?}#{whole}.#{format('%02d', fraction)}"
  end
end
