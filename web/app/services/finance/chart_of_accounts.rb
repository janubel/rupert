# frozen_string_literal: true

module Finance
  # Seeds the standard chart of accounts for the current tenant. Idempotent:
  # existing account codes are left untouched, so re-running never duplicates
  # or overwrites custom accounts the user has added.
  class ChartOfAccounts
    DEFAULT = [
      # Assets
      { code: '1000', name: 'Cash', type: 'asset' },
      { code: '1100', name: 'Checking account', type: 'asset' },
      { code: '1150', name: 'Card settlements receivable', type: 'asset' },
      { code: '1200', name: 'Accounts receivable', type: 'asset' },
      { code: '1300', name: 'Inventory', type: 'asset' },
      { code: '1400', name: 'Fixed assets', type: 'asset' },
      { code: '1500', name: 'Accumulated depreciation', type: 'asset' },
      # Liabilities
      { code: '2000', name: 'Accounts payable', type: 'liability' },
      { code: '2100', name: 'Sales tax payable', type: 'liability' },
      { code: '2200', name: 'Credit cards payable', type: 'liability' },
      { code: '2300', name: 'Loans payable', type: 'liability' },
      # Equity
      { code: '3000', name: "Owner's equity", type: 'equity' },
      { code: '3100', name: 'Retained earnings', type: 'equity' },
      # Revenue
      { code: '4000', name: 'Sales revenue', type: 'revenue' },
      { code: '4100', name: 'Shipping income', type: 'revenue' },
      { code: '4200', name: 'Refunds', type: 'revenue' },
      { code: '4300', name: 'Other income', type: 'revenue' },
      # Expenses
      { code: '5000', name: 'Cost of goods sold', type: 'expense' },
      { code: '5100', name: 'Shipping & freight', type: 'expense' },
      { code: '5200', name: 'Rent', type: 'expense' },
      { code: '5300', name: 'Utilities', type: 'expense' },
      { code: '5400', name: 'Payroll', type: 'expense' },
      { code: '5500', name: 'Marketing & advertising', type: 'expense' },
      { code: '5510', name: 'Advertising', type: 'expense' },
      { code: '5600', name: 'Software & subscriptions', type: 'expense' },
      { code: '5700', name: 'Supplies', type: 'expense' },
      { code: '5750', name: 'Store expenses', type: 'expense' },
      { code: '5800', name: 'Insurance', type: 'expense' },
      { code: '5900', name: 'Taxes & licenses', type: 'expense' },
      { code: '6000', name: 'Bank & processing fees', type: 'expense' },
      { code: '6100', name: 'Other expenses', type: 'expense' }
    ].freeze

    def self.seed!
      existing = Account.pluck(:code).map(&:downcase)
      DEFAULT.each do |attrs|
        next if existing.include?(attrs[:code].downcase)

        Account.create!(
          code: attrs[:code],
          name: attrs[:name],
          account_type: attrs[:type]
        )
      end
      Account.count
    end
  end
end
