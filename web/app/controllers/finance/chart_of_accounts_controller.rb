# frozen_string_literal: true

module Finance
  # Chart of accounts: the ledger's account codes, grouped by type. New tenants
  # get the standard chart seeded automatically; existing tenants are seeded on
  # first visit if empty (idempotent).
  class ChartOfAccountsController < AuthenticatedController
    before_action :seed_if_empty
    before_action :set_account, only: %i[show edit update archive restore]

    def index
      authorize(:module, :finance_read?)
      accounts = Account.ordered
      @grouped = Account::TYPES.each_with_object({}) do |type, out|
        out[type] = accounts.select { |a| a.account_type == type }
      end
      @active_count = accounts.count(&:active)
    end

    # Every posted line that touched one account, in date order. Read-only.
    def show
      authorize(:module, :finance_read?)
      @from = parse_date(params[:from])
      @to = parse_date(params[:to])
      @rows = GeneralLedger.new(from: @from, to: @to).account_ledger(@account)
      @total_debit = @rows.sum { |row| row[:line].debit_cents.to_i }
      @total_credit = @rows.sum { |row| row[:line].credit_cents.to_i }
      response.headers['Cache-Control'] = 'private, no-store'
    end

    def new
      authorize(:module, :finance_write?)
      @account = Account.new
    end

    def create
      authorize(:module, :finance_write?)
      @account = Account.new(account_params)
      if @account.save
        ActivityLogger.log('account_created', subject: @account, details: account_summary(@account))
        redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} created."
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :finance_write?)
    end

    def update
      authorize(:module, :finance_write?)
      if @account.update(account_params)
        changes = @account.saved_changes.except('updated_at')
        ActivityLogger.log('account_updated', subject: @account, details: changes.map { |field, (from, to)| "#{field}: #{from.inspect} → #{to.inspect}" }.join('; ')) if changes.any?
        redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} updated."
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def archive
      authorize(:module, :finance_write?)
      @account.update!(active: false)
      ActivityLogger.log('account_archived', subject: @account, details: @account.code)
      redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} archived."
    end

    def restore
      authorize(:module, :finance_write?)
      @account.update!(active: true)
      ActivityLogger.log('account_restored', subject: @account, details: @account.code)
      redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} restored."
    end

    private

    def set_account
      @account = Account.find(params[:id])
    end

    # Guarantee the standard chart exists without requiring a rake step.
    def seed_if_empty
      ChartOfAccounts.seed! if Current.user&.can?('finance.read') && Account.count.zero?
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end

    def account_summary(account)
      "#{account.code} · #{account.account_type} · #{account.normal_balance}"
    end

    def account_params
      params.require(:account).permit(:code, :name, :account_type, :normal_balance, :description, :active)
    end
  end
end
