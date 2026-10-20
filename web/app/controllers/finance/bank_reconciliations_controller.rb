# frozen_string_literal: true

module Finance
  # Bank reconciliation workbench (roadmap F40). Shows statement lines beside
  # suggested general-ledger matches and lets a person confirm or clear each
  # pairing. Suggestions are computed read-only; confirming persists the link.
  class BankReconciliationsController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }
    before_action -> { authorize(:module, :finance_write?) }, only: %i[match unmatch ignore map_account]

    def index
      @account_label = params[:account_label].presence || default_account_label
      @from = parse_date(params[:from]) || default_from
      @to = parse_date(params[:to]) || default_to
      @reconciliation = BankReconciliation.new(account_label: @account_label, from: @from, to: @to,
        window_days: params[:window_days])
      @account_labels = BankStatementLine.distinct.order(:account_label).pluck(:account_label)
      response.headers['Cache-Control'] = 'private, no-store'
    end

    def map_account
      label = BankStatementLine.where(account_label: params[:account_label]).limit(1).pick(:account_label)
      raise ActiveRecord::RecordNotFound unless label

      account = BankStatementAccount.available_accounts.find(params[:ledger_account_id])
      mapping = BankStatementAccount.find_or_initialize_by(account_label: label)
      save_mapping = -> { mapping.update!(ledger_account: account) }
      BankStatementAccount.transaction do
        # Serialize first-time mappings with statement decisions, including legacy labels.
        Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
        mapping.persisted? ? mapping.with_lock(&save_mapping) : save_mapping.call
      end
      ActivityLogger.log('bank_statement_account_mapped', subject: mapping,
        details: "Statement account mapped to ledger account ##{account.id}")
      redirect_to finance_bank_reconciliation_path(account_label: label, from: params[:from], to: params[:to]),
        notice: 'Statement ledger account saved. Existing records were preserved.'
    end

    def match
      line = BankStatementLine.find(params[:line_id])
      entry = JournalEntry.posted.find(params[:journal_entry_id])
      line.match!(journal_entry: entry, user: Current.user)
      ActivityLogger.log('bank_line_matched', subject: line,
        details: "Statement line ##{line.id} (#{line.amount_cents}) matched to journal entry ##{entry.id}")
      redirect_to finance_bank_reconciliation_path(account_label: line.account_label, from: params[:from], to: params[:to]),
        notice: 'Matched to the ledger.'
    end

    def unmatch
      line = BankStatementLine.find(params[:line_id])
      line.unmatch!(user: Current.user)
      redirect_to finance_bank_reconciliation_path(account_label: line.account_label, from: params[:from], to: params[:to]),
        notice: 'Match cleared.'
    end

    # Mark a statement line ignored (e.g. a suspected duplicate) so it drops out
    # of reconciliation and duplicate detection.
    def ignore
      line = BankStatementLine.find(params[:line_id])
      line.decide!(status: 'ignored', user: Current.user)
      ActivityLogger.log('bank_line_ignored', subject: line,
        details: "Statement line ##{line.id} (#{line.amount_cents}) marked ignored")
      redirect_to finance_bank_reconciliation_path(account_label: line.account_label, from: params[:from], to: params[:to]),
        notice: 'Line ignored.'
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      redirect_to finance_bank_reconciliation_path(from: params[:from], to: params[:to]),
        alert: error.record.errors.full_messages.to_sentence
    end

    rescue_from ActiveRecord::RecordNotUnique do
      redirect_to finance_bank_reconciliation_path(from: params[:from], to: params[:to]),
        alert: 'That ledger entry is already matched to another statement line.'
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
