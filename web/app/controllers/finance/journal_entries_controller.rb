# frozen_string_literal: true

module Finance
  # General ledger: the balanced journal entries that back the books. Entries
  # produced automatically by Finance::Posting are read-only here; this
  # controller also lets an accountant post a manual entry (an adjustment,
  # accrual, opening balance or owner draw) through the same balanced path.
  class JournalEntriesController < AuthenticatedController
    before_action -> { authorize(:module, :finance_write?) }, only: %i[new create]

    def index
      authorize(:module, :finance_read?)
      @can_write = Current.user.can?('finance.write')
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

    def new
      @entry = JournalEntry.new(posted_on: Date.current, kind: 'manual')
      @accounts = Finance::Account.active.ordered
    end

    def create
      lines = manual_line_params.filter_map do |lp|
        next if lp[:account_id].blank?

        debit = to_cents(lp[:debit])
        credit = to_cents(lp[:credit])
        next if debit.zero? && credit.zero?

        { account_id: lp[:account_id].to_i, debit_cents: debit, credit_cents: credit, memo: lp[:memo] }
      end
      @entry = JournalEntry.post!(kind: 'manual', posted_on: params[:posted_on], memo: params[:memo],
                                  lines: lines, created_by: Current.user)
      ActivityLogger.log('journal_entry_created', subject: @entry,
        details: "Manual entry · #{@entry.debit_cents} cents on #{@entry.posted_on}")
      redirect_to finance_journal_entry_path(@entry), notice: 'Journal entry posted.'
    rescue ActiveRecord::RecordInvalid => e
      @accounts = Finance::Account.active.ordered
      @entry = e.record.is_a?(JournalEntry) ? e.record : JournalEntry.new(kind: 'manual')
      @form_error = e.record.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end

    private

    def manual_line_params
      Array(params.permit(lines: [:account_id, :debit, :credit, :memo]).to_h['lines'])
    end

    def to_cents(value)
      text = value.to_s.strip
      return 0 unless text.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/)

      (BigDecimal(text) * 100).to_i
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
