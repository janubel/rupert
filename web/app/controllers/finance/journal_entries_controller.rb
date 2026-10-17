# frozen_string_literal: true

module Finance
  # General ledger: the balanced journal entries that back the books. Read-only
  # here — entries are produced by Finance::Posting from source records, not
  # typed by hand in v1.
  class JournalEntriesController < AuthenticatedController
    def index
      authorize(:module, :finance_read?)
      @kind = JournalEntry::KINDS.include?(params[:kind]) ? params[:kind] : 'all'
      @from = parse_date(params[:from])
      @to = parse_date(params[:to])

      scope = JournalEntry.in_range(@from, @to).recent
      scope = scope.where(kind: @kind) if @kind != 'all'

      totals_scope = JournalEntry.in_range(@from, @to)
      totals_scope = totals_scope.where(kind: @kind) if @kind != 'all'
      entry_ids = totals_scope.pluck(:id)
      @totals = {
        entries: entry_ids.size,
        debits: entry_ids.any? ? JournalLine.where(journal_entry_id: entry_ids).sum(:debit_cents) : 0,
        credits: entry_ids.any? ? JournalLine.where(journal_entry_id: entry_ids).sum(:credit_cents) : 0
      }

      @pagy, @entries = pagy(scope, items: 50)
      response.headers['Cache-Control'] = 'private, no-store'
    end

    def show
      authorize(:module, :finance_read?)
      @entry = JournalEntry.includes(journal_lines: :account).find(params[:id])
    end

    private

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
