# frozen_string_literal: true

module Finance
  # The three core statements, computed from posted journal lines. A shared date
  # window drives trial balance and the income statement; the balance sheet is
  # cumulative through the chosen date.
  class ReportsController < AuthenticatedController
    before_action :set_window

    def index
      authorize(:module, :finance_read?)
    end

    def trial_balance
      authorize(:module, :finance_read?)
      @rows = Finance::GeneralLedger.new(from: @from, to: @to).trial_balance
      @total_debit = @rows.sum(&:debit)
      @total_credit = @rows.sum(&:credit)
      render_statement('Trial balance')
    end

    def income_statement
      authorize(:module, :finance_read?)
      @statement = Finance::GeneralLedger.new(from: @from, to: @to).income_statement
      render_statement('Income statement')
    end

    def balance_sheet
      authorize(:module, :finance_read?)
      @sheet = Finance::GeneralLedger.new(to: @to).balance_sheet
      render_statement('Balance sheet')
    end

    private

    def set_window
      @from = parse_date(params[:from]) || Date.current.beginning_of_month
      @to = parse_date(params[:to]) || Date.current
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end

    def balance_state
      balanced = action_name == 'trial_balance' ? @total_debit == @total_credit : @sheet[:total_assets] == @sheet[:total_liabilities] + @sheet[:total_equity]
      balanced ? 'Balanced' : 'Out of balance'
    end

    def render_statement(_title)
      respond_to do |format|
        format.html { render action_name.to_sym }
        format.csv { send_data statement_csv, filename: "#{action_name}-#{@from}-#{@to}.csv" }
      end
    end

    def statement_csv
      require 'csv'
      CSV.generate do |csv|
        csv << [action_name.humanize, "From #{@from}", "To #{@to}", 'Amounts in USD']
        csv << ['Status', balance_state] if action_name != 'income_statement'
        case action_name
        when 'trial_balance'
          csv << %w[Code Account Debit Credit Balance]
          @rows.each { |r| csv << [r.account.code, safe(r.account.name), cents(r.debit), cents(r.credit), cents(r.balance)] }
          csv << ['', 'Totals', cents(@total_debit), cents(@total_credit), '']
        when 'income_statement'
          csv << %w[Code Account Balance]
          csv << ['Revenue']
          @statement[:revenue].each { |r| csv << [r.account.code, safe(r.account.name), cents(r.balance)] }
          csv << ['', 'Total revenue', cents(@statement[:total_revenue])]
          csv << ['Expenses']
          @statement[:expense].each { |r| csv << [r.account.code, safe(r.account.name), cents(r.balance)] }
          csv << ['', 'Total expenses', cents(@statement[:total_expense])]
          csv << ['', 'Net income', cents(@statement[:net_income])]
        when 'balance_sheet'
          csv << %w[Code Account Balance]
          csv << ['Assets']
          @sheet[:assets].each { |r| csv << [r.account.code, safe(r.account.name), cents(r.balance)] }
          csv << ['', 'Total assets', cents(@sheet[:total_assets])]
          csv << ['Liabilities']
          @sheet[:liabilities].each { |r| csv << [r.account.code, safe(r.account.name), cents(r.balance)] }
          csv << ['', 'Total liabilities', cents(@sheet[:total_liabilities])]
          csv << ['Equity']
          @sheet[:equity].each { |r| csv << [r.account.code, safe(r.account.name), cents(r.balance)] }
          csv << ['', 'Current period earnings', cents(@sheet[:current_period_earnings])]
          csv << ['', 'Total equity', cents(@sheet[:total_equity])]
        end
      end
    end

    def cents(value) = FinanceHelper.cents_to_decimal(value.to_i)

    def safe(value) = FinanceHelper.csv_safe(value)
  end
end
