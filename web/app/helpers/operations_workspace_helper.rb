# frozen_string_literal: true

module OperationsWorkspaceHelper
  # "g then letter" jump keys for the Finance workspace links.
  FINANCE_SHORTCUTS = {
    'Books desk' => 'd', 'Daily reconciliation' => 'r', 'Day close' => 'c', 'Book approvals' => 'a', 'Follow-ups' => 'f',
    'Bank statements' => 'b', 'Source documents' => 's', 'Accounts' => 'o', 'Receipts' => 'p', 'Expenses' => 'e',
    'Vendor payments' => 'v', 'By payee' => 'y', 'Chart of accounts' => 't', 'Ledger' => 'l', 'Source reports' => 'u',
    'Cash forecast' => 'w', 'Business snapshot' => 'n', 'Books health' => 'h', 'Period locks' => 'k', 'Cash flow' => 'm'
  }.freeze

  def operations_workspace_page?
    controller_path.start_with?('finance/') || %w[bookkeeping books_desks period_locks sales inventory product_names inventory_counts inventory_count_scans inventory_exceptions reconcile ledger financial_close business_snapshots bank_statements book_approvals books_check daily_reconciliations reconciliation_follow_ups reconciliation_documents money_reconciliations cash_forecasts].include?(controller_path)
  end

  def operations_source_name(value)
    DashboardSales::LABELS.fetch(value, value.to_s.humanize)
  end

  def operations_money(cents, currency: 'USD')
    return 'Unknown' if cents.nil?

    amount = BigDecimal(cents.to_s) / 100
    figure = number_with_precision(amount.abs, precision: 2, delimiter: ',')
    sign = amount.negative? ? '−' : ''
    # Dollars read as $1,234.56 (docs/ui-standards.md §7); other currencies keep their code.
    return "#{sign}$#{figure}" if currency.to_s.upcase == 'USD'

    "#{sign}#{currency.presence || 'Unknown currency'} #{figure}"
  end
end
