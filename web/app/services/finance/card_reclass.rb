# frozen_string_literal: true

module Finance
  # Sales posted before card receipts had their own account debited Cash for
  # card payments. Posted entries are never edited, so this moves that money
  # to "Card settlements receivable" with one dated entry per month: debit
  # 1150, credit 1000, for the card receipts still sitting in Cash that month.
  # It is a delta against earlier reclass entries, so re-running is safe and a
  # payment that was voided and re-posted since is picked up. `plan` changes
  # nothing.
  class CardReclass
    SOURCE_TYPE = 'Finance::CardReclass'
    Row = Struct.new(:month, :payments, :amount_cents, keyword_init: true)

    def initialize(created_by: nil)
      @created_by = created_by
    end

    # Read-only: it never seeds the chart, so a dry run writes nothing.
    def plan
      cash = Account.find_by(code: Posting::FALLBACK_CASH_CODE)
      return [] unless cash

      clearing = Account.find_by(code: Posting::CARD_CLEARING_CODE)
      moved = clearing ? already_moved(clearing) : {}
      card_receipts(cash).filter_map do |month, payments, cents|
        delta = cents.to_i - moved.fetch(month, 0)
        Row.new(month: month, payments: payments, amount_cents: delta) unless delta.zero?
      end
    end

    # Returns [posted rows, refused rows with a reason].
    def apply!
      posted = []
      refused = []
      plan.each do |row|
        post(row)
        posted << row
      rescue ActiveRecord::RecordInvalid, Posting::Error => e
        refused << [row, e.message]
      end
      [posted, refused]
    end

    private

    def post(row)
      from = Posting.ledger_account(Posting::FALLBACK_CASH_CODE)
      to = Posting.ledger_account(Posting::CARD_CLEARING_CODE)
      amount = row.amount_cents.abs
      lines = [{ account_id: to.id, debit_cents: amount, memo: to.name }, { account_id: from.id, credit_cents: amount, memo: from.name }]
      lines.reverse! if row.amount_cents.negative?
      year, month = row.month.split('-').map(&:to_i)
      JournalEntry.post!(
        kind: 'manual', posted_on: Date.new(year, month, -1), created_by: @created_by, lines: lines,
        memo: "Reclassify card receipts from Cash to Card settlements receivable · #{row.month}",
        source_type: SOURCE_TYPE, source_id: "#{row.month}:#{sequence_for(row.month)}"
      )
    end

    # Void entries count too, so a month's source ids never repeat.
    def sequence_for(month)
      JournalEntry.where(source_type: SOURCE_TYPE).where('source_id LIKE ?', "#{month}:%").count + 1
    end

    # Card payments' receipts still debited to Cash, by month of the sale entry.
    def card_receipts(cash)
      JournalLine.joins(:journal_entry)
                 .joins('INNER JOIN payments ON payments.tenant_id = journal_entries.tenant_id ' \
                        'AND payments.id = CAST(journal_entries.source_id AS INTEGER)')
                 .where(journal_entries: { status: 'posted', kind: 'sale', source_type: 'Core::Payment' })
                 .where(payments: { method: 'card' }).where(account_id: cash.id).where('journal_lines.debit_cents > 0')
                 .group(Arel.sql('substr(journal_entries.posted_on, 1, 7)')).order(Arel.sql('substr(journal_entries.posted_on, 1, 7)'))
                 .pluck(Arel.sql('substr(journal_entries.posted_on, 1, 7)'), Arel.sql('COUNT(*)'), Arel.sql('SUM(journal_lines.debit_cents)'))
    end

    # Net amount already moved per month: debits to 1150 minus credits to 1150.
    def already_moved(clearing)
      JournalLine.joins(:journal_entry)
                 .where(journal_entries: { status: 'posted', source_type: SOURCE_TYPE }).where(account_id: clearing.id)
                 .group(Arel.sql('substr(journal_entries.posted_on, 1, 7)'))
                 .pluck(Arel.sql('substr(journal_entries.posted_on, 1, 7)'), Arel.sql('SUM(journal_lines.debit_cents - journal_lines.credit_cents)'))
                 .to_h { |month, cents| [month, cents.to_i] }
    end
  end
end
