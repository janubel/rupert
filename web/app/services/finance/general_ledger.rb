# frozen_string_literal: true

module Finance
  # Reads posted journal lines into the standard financial statements (roadmap
  # F39). All amounts are integer cents; balances are signed by each account's
  # normal side so a credit-normal account (liability/equity/revenue) shows a
  # positive number when it is credit-heavy, and a debit-normal account
  # (asset/expense) shows positive when debit-heavy.
  #
  # Nothing here writes. It only ever reads `posted` entries, so a voided entry
  # disappears from every statement automatically.
  class GeneralLedger
    Row = Struct.new(:account, :debit, :credit, :balance, keyword_init: true)

    def initialize(from: nil, to: nil)
      @from = coerce(from)
      @to = coerce(to)
    end

    # Every account with movement in the window: period debit, period credit and
    # the natural-signed balance. Ordered by account code.
    def trial_balance
      totals = movement_by_account
      accounts(totals.keys).map do |account|
        t = totals[account.id]
        Row.new(account: account, debit: t[:debit], credit: t[:credit], balance: natural(account, t[:net]))
      end
    end

    def income_statement
      totals = movement_by_account
      revenue = rows_for('revenue', totals)
      expense = rows_for('expense', totals)
      total_revenue = revenue.sum(&:balance)
      total_expense = expense.sum(&:balance)
      {
        revenue: revenue,
        expense: expense,
        total_revenue: total_revenue,
        total_expense: total_expense,
        net_income: total_revenue - total_expense
      }
    end

    # Cumulative balances through `to` (ignores `from`). Because opening
    # balances are not posted, current-period earnings are shown as their own
    # equity line so Assets = Liabilities + Equity holds for an unclosed period.
    def balance_sheet
      totals = movement_by_account(from: nil, to: @to)
      assets = rows_for('asset', totals)
      liabilities = rows_for('liability', totals)
      equity_accounts = rows_for('equity', totals)
      earnings = cumulative_net_income
      {
        assets: assets,
        liabilities: liabilities,
        equity: equity_accounts,
        current_period_earnings: earnings,
        total_assets: assets.sum(&:balance),
        total_liabilities: liabilities.sum(&:balance),
        total_equity: equity_accounts.sum(&:balance) + earnings,
        as_of: @to
      }.tap do |sheet|
        sheet[:balanced] = sheet[:total_assets] == sheet[:total_liabilities] + sheet[:total_equity]
      end
    end

    # Running ledger for one account across the window.
    def account_ledger(account, from: @from, to: @to)
      lines = JournalLine.joins(:journal_entry)
                         .merge(JournalEntry.posted)
                         .where(account_id: account.id)
      lines = lines.where('journal_entries.posted_on >= ?', from) if from
      lines = lines.where('journal_entries.posted_on <= ?', to) if to
      lines = lines.order('journal_entries.posted_on, journal_entries.id, journal_lines.position')
      running = 0
      lines.map do |line|
        running += line.debit_cents.to_i - line.credit_cents.to_i
        { entry: line.journal_entry, line: line, running_balance: natural(account, running) }
      end
    end

    private

    def coerce(value)
      return nil if value.blank?

      value.is_a?(Date) ? value : Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def base_scope(from, to)
      scope = JournalLine.joins(:journal_entry).merge(JournalEntry.posted)
      scope = scope.where('journal_entries.posted_on >= ?', from) if from
      scope = scope.where('journal_entries.posted_on <= ?', to) if to
      scope
    end

    # { account_id => { debit:, credit:, net: } } where net = debit - credit.
    def movement_by_account(from: @from, to: @to)
      scope = base_scope(from, to)
      debit = scope.group(:account_id).sum(:debit_cents)
      credit = scope.group(:account_id).sum(:credit_cents)
      (debit.keys | credit.keys).each_with_object({}) do |id, hash|
        d = debit[id] || 0
        c = credit[id] || 0
        hash[id] = { debit: d, credit: c, net: d - c }
      end
    end

    def accounts(ids)
      Finance::Account.where(id: ids).ordered.to_a
    end

    def rows_for(type, totals)
      Finance::Account.where(account_type: type, id: totals.keys).ordered.map do |account|
        t = totals[account.id]
        Row.new(account: account, debit: t[:debit], credit: t[:credit], balance: natural(account, t[:net]))
      end
    end

    # Natural-signed balance: debit-normal accounts keep net; credit-normal
    # accounts flip it so a credit balance reads positive.
    def natural(account, net)
      account.normal_balance == 'debit' ? net : -net
    end

    def cumulative_net_income
      totals = movement_by_account(from: nil, to: @to)
      revenue = totals.slice(*Finance::Account.where(account_type: 'revenue').pluck(:id)).values.sum { |t| -t[:net] }
      expense = totals.slice(*Finance::Account.where(account_type: 'expense').pluck(:id)).values.sum { |t| t[:net] }
      revenue - expense
    end
  end
end
