# frozen_string_literal: true

module Finance
  # Bank reconciliation workbench (roadmap F40). Shows statement lines beside
  # suggested general-ledger matches and lets a person confirm or clear each
  # pairing. Suggestions are computed read-only; confirming persists the link.
  class BankReconciliationsController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }
    before_action -> { authorize(:module, :finance_write?) }, only: %i[match unmatch]

    def index
      @account_label = params[:account_label].presence || default_account_label
      @from = parse_date(params[:from]) || default_from
      @to = parse_date(params[:to]) || default_to
      @reconciliation = BankReconciliation.new(account_label: @account_label, from: @from, to: @to,
                                                window_days: params[:window_days])
      @account_labels = BankStatementLine.distinct.order(:account_label).pluck(:account_label)
      response.headers['Cache-Control'] = 'private, no-store'
    end

    def match
      line = BankStatementLine.find(params[:line_id])
      entry = JournalEntry.posted.find(params[:journal_entry_id])
      line.match!(journal_entry: entry, user: Current.user)
      ActivityLogger.log('bank_line_matched', subject: line,
        details: "Statement line ##{line.id} (#{line.amount_cents}) matched to journal entry ##{entry.id}")
      redirect_to bank_reconciliation_path(account_label: line.account_label, from: params[:from], to: params[:to]),
        notice: 'Matched to the ledger.'
    end

    def unmatch
      line = BankStatementLine.find(params[:line_id])
      line.unmatch!(user: Current.user)
      redirect_to bank_reconciliation_path(account_label: line.account_label, from: params[:from], to: params[:to]),
        notice: 'Match cleared.'
    end

    private

    def default_account_label
      BankStatementLine.order(created_at: :desc).limit(1).pick(:account_label) || BankStatementLine.distinct.order(:account_label).pick(:account_label)
    end

    def default_from
      BankStatementLine.where(account_label: @account_label).minimum(:posted_on) || Date.current.beginning_of_month
    end

    def default_to
      BankStatementLine.where(account_label: @account_label).maximum(:posted_on) || Date.current
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
