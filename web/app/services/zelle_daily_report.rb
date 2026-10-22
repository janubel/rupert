# frozen_string_literal: true

# Daily Zelle totals by bank posting date. A separate source: nothing here is
# added to SwipeSimple card/cash totals, Core::Order or the ledger, and entries
# stay "unverified" until a person reconciles them against the bank.
class ZelleDailyReport
  attr_reader :day

  def initialize(day: Date.current.iso8601)
    raise ArgumentError unless day.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    @day = Date.iso8601(day)
  end

  def entries
    ZelleEntry.latest.where(posted_on: day)
  end

  def totals
    entries.includes(:zelle_export).group_by { |entry| [entry.zelle_export.account_label, entry.zelle_export.currency] }
      .map do |(account, currency), rows|
        credits = rows.select { |row| row.direction == 'credit' }
        debits = rows.select { |row| row.direction == 'debit' }
        { account: account, currency: currency, tender: ZelleEntry::TENDER, verification: 'unverified',
          credit_count: credits.length, credit_cents: credits.sum(&:amount_cents),
          debit_count: debits.length, debit_cents: debits.sum(&:amount_cents),
          net_cents: credits.sum(&:amount_cents) - debits.sum(&:amount_cents) }
      end
  end
end
