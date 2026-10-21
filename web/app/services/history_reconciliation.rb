# frozen_string_literal: true

# Read-only comparisons of imported QuickBooks history with Rupert's own books
# and bank evidence, for the periods where both exist. It lists differences and
# the reason a comparison could not be made. It never adjusts, matches or
# resolves anything: a difference is a question for a person.
#
# Amounts are integer cents, signed debit-minus-credit, so a positive number is
# a net debit on both sides.
class HistoryReconciliation
  AccountRow = Struct.new(:account_id, :account_label, :quickbooks_cents, :rupert_cents, :difference_cents, :note, keyword_init: true)
  MonthRow = Struct.new(:month, :account_label, :quickbooks_cents, :bank_cents, :difference_cents, :note, keyword_init: true)
  Comparison = Struct.new(:title, :period, :rows, :message, :unmapped, keyword_init: true)

  ROW_LIMIT = 200

  def ledger
    @ledger ||= build_ledger
  end

  def trial_balances
    @trial_balances ||= build_trial_balances
  end

  def bank
    @bank ||= build_bank
  end

  private

  def build_ledger
    qb_range = live_transactions.then { |scope| [scope.minimum(:txn_date), scope.maximum(:txn_date)] }
    native = Finance::JournalEntry.posted.where.not(kind: 'imported')
    native_range = [native.minimum(:posted_on), native.maximum(:posted_on)]
    from, to = overlap(qb_range, native_range)
    if from.nil?
      message = if qb_range.first.nil? then 'No QuickBooks journal has been uploaded yet.'
      elsif native_range.first.nil? then 'Rupert has no entries of its own yet, so there is nothing to compare with.'
      else "QuickBooks covers #{qb_range.first} to #{qb_range.last} and Rupert’s own entries cover #{native_range.first} to #{native_range.last}: no days in common."
      end
      return Comparison.new(title: 'QuickBooks journal vs Rupert ledger', rows: [], message: message, unmapped: [])
    end

    qb, unmapped = quickbooks_by_account(from, to)
    rupert = net_by_account(native.where(posted_on: from..to))
    Comparison.new(title: 'QuickBooks journal vs Rupert ledger', period: [from, to], rows: account_rows(qb, rupert), unmapped: unmapped)
  end

  def build_trial_balances
    trial_balance_batches.map do |batch|
      as_of = batch.as_of
      qb = Hash.new(0)
      unmapped = []
      batch.lines.where(record_type: 'balance', status: %w[staged posted]).pluck(:account_name, :debit_cents, :credit_cents).each do |name, debit, credit|
        target = account_mappings[ImportEntityMapping.key_for(name)]
        target ? qb[target] += debit - credit : unmapped << name
      end
      rupert = net_by_account(Finance::JournalEntry.posted.where('posted_on <= ?', as_of))
      Comparison.new(title: "QuickBooks trial balance as of #{as_of} vs Rupert ledger", period: [nil, as_of], rows: account_rows(qb, rupert, opening_note: true), unmapped: unmapped.uniq)
    end
  end

  def build_bank
    accounts = BankStatementAccount.includes(:ledger_account).to_a
    return [] if accounts.empty? || live_transactions.none?

    qb_months = qb_net_by_month
    accounts.filter_map do |bank_account|
      ledger_account = bank_account.ledger_account
      qb = qb_months.select { |(name, _), _| account_mappings[ImportEntityMapping.key_for(name)] == ledger_account.id }
                    .each_with_object(Hash.new(0)) { |((_, month), cents), sums| sums[month] += cents }
      statement = BankStatementLine.where(account_label: bank_account.account_label)
                    .group(Arel.sql("strftime('%Y-%m', posted_on)")).sum(:amount_cents)
      next if qb.empty? && statement.empty?

      Comparison.new(title: "#{bank_account.account_label}: QuickBooks vs bank statement lines", period: nil, unmapped: [],
        rows: month_rows(ledger_account, qb, statement))
    end
  end

  def live_transactions
    ImportTransaction.where(status: %w[staged posted], batch_id: journal_batch_ids)
  end

  def journal_batch_ids
    ImportBatch.where(source: 'quickbooks', kind: 'journal', status: %w[staged approved]).select(:id)
  end

  def trial_balance_batches
    ImportBatch.where(source: 'quickbooks', kind: 'trial_balance', status: %w[staged approved]).order(as_of: :desc, id: :desc).to_a.uniq(&:as_of).first(5)
  end

  def overlap(first, second)
    return [nil, nil] if first.any?(&:nil?) || second.any?(&:nil?)

    from = [first.first, second.first].max
    to = [first.last, second.last].min
    from <= to ? [from, to] : [nil, nil]
  end

  # source_key => Rupert account id for accounts the person chose to map.
  def account_mappings
    @account_mappings ||= ImportEntityMapping.where(entity_type: 'account', decision: 'map').where.not(target_id: nil).pluck(:source_key, :target_id).to_h
  end

  def quickbooks_by_account(from, to)
    sums = Hash.new(0)
    unmapped = []
    lines = ImportLine.where(batch_id: journal_batch_ids, record_type: 'transaction_line', status: %w[staged posted], txn_date: from..to)
    lines.group(:account_name).pluck(:account_name, Arel.sql('SUM(debit_cents)'), Arel.sql('SUM(credit_cents)')).each do |name, debit, credit|
      target = account_mappings[ImportEntityMapping.key_for(name)]
      target ? sums[target] += debit.to_i - credit.to_i : unmapped << name
    end
    [sums, unmapped.sort]
  end

  def qb_net_by_month
    lines = ImportLine.where(batch_id: journal_batch_ids, record_type: 'transaction_line', status: %w[staged posted])
    lines.group(:account_name, Arel.sql("strftime('%Y-%m', txn_date)")).pluck(:account_name, Arel.sql("strftime('%Y-%m', txn_date)"), Arel.sql('SUM(debit_cents)'), Arel.sql('SUM(credit_cents)'))
      .each_with_object({}) { |(name, month, debit, credit), sums| sums[[name, month]] = debit.to_i - credit.to_i }
  end

  def net_by_account(entries)
    Finance::JournalLine.where(journal_entry_id: entries.select(:id)).group(:account_id).pluck(:account_id, Arel.sql('SUM(debit_cents)'), Arel.sql('SUM(credit_cents)'))
      .to_h { |id, debit, credit| [id, debit.to_i - credit.to_i] }
  end

  def account_rows(qb, rupert, opening_note: false)
    ids = (qb.keys | rupert.keys)
    mapped = account_mappings.values
    accounts = Finance::Account.where(id: ids).index_by(&:id)
    rows = ids.filter_map do |id|
      quickbooks = qb.fetch(id, 0)
      books = rupert.fetch(id, 0)
      next if quickbooks.zero? && books.zero?

      note = if !qb.key?(id) && mapped.include?(id) then 'The mapped QuickBooks account has no activity or balance in this comparison.'
      elsif !qb.key?(id) then 'No QuickBooks account is mapped to this one.'
      elsif !rupert.key?(id) then 'Rupert has no entries on this account in the period.'
      elsif opening_note && quickbooks != books then 'Opening balances before Rupert’s first entry are not posted in Rupert, so a difference is expected here.'
      end
      AccountRow.new(account_id: id, account_label: accounts[id]&.label || "Account ##{id}", quickbooks_cents: quickbooks, rupert_cents: books,
        difference_cents: quickbooks - books, note: note)
    end
    rows.sort_by { |row| [-row.difference_cents.abs, row.account_label] }.first(ROW_LIMIT)
  end

  def month_rows(ledger_account, qb, statement)
    (qb.keys | statement.keys).sort.map do |month|
      quickbooks = qb[month]
      bank = statement[month]
      note = if qb.key?(month) && !statement.key?(month) then 'No bank statement lines uploaded for this month.'
      elsif statement.key?(month) && !qb.key?(month) then 'No QuickBooks activity on the mapped account this month.'
      end
      MonthRow.new(month: month, account_label: ledger_account.label, quickbooks_cents: quickbooks, bank_cents: bank,
        difference_cents: (quickbooks.to_i - bank.to_i), note: note)
    end.last(ROW_LIMIT)
  end
end
