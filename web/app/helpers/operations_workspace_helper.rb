# frozen_string_literal: true

module OperationsWorkspaceHelper
  def operations_links(workspace, day: nil)
    date = (day || Date.yesterday).iso8601
    entries = case workspace.to_sym
    when :sales
      [['Sales journal', sales_path(date: date), 'sales.read', 'sales'],
       ['Retail POS', ctrax_pos_path, 'pos', 'ctrax_pos'],
       ['C-Trax daily close', ctrax_days_path(date: date), 'sales.read', 'ctrax_days'],
       ['Registers', sales_pos_sessions_path, 'sales.read', 'sales/pos_sessions']]
    when :stock
      [['Stock comparison', inventory_index_path, 'inventory.read', 'inventory'],
       ['Physical counts', inventory_counts_path, 'inventory.read', 'inventory_counts'],
       ['Stock review', inventory_exceptions_path, 'inventory.read', 'inventory_exceptions'],
       ['Movements', movements_inventory_index_path, 'inventory.read', 'inventory/movements'],
       ['Catalog links', reconcile_index_path, 'reconcile.read', 'reconcile']]
    when :money, :finance
      [['Books desk', books_desk_path, 'reports.read', 'books_desks', 'Daily & weekly'],
       ['Daily reconciliation', daily_reconciliations_path(day: date), 'reports.read', 'daily_reconciliations', 'Daily & weekly'],
       ['Day close', financial_close_path(day: date), 'reports.read', 'financial_close', 'Daily & weekly'],
       ['Book approvals', book_approvals_path, 'reports.read', 'book_approvals', 'Daily & weekly'],
       ['Follow-ups', reconciliation_follow_ups_path(day: date), 'reports.read', 'reconciliation_follow_ups', 'Daily & weekly'],
       ['Bank statements', bank_statements_path, 'finance.read', 'bank_statements', 'Records'],
       ['Source documents', reconciliation_documents_path(from: date, to: date, close_day: date), 'reports.read', 'reconciliation_documents', 'Records'],
       ['Accounts', finance_accounts_path, 'finance.read', 'finance/accounts', 'Records'],
       ['Receipts', receipts_path, 'finance.read', 'receipts', 'Records'],
       ['Expenses', finance_expenses_path, 'finance.read', 'finance/expenses', 'Records'],
       ['Vendor payments', finance_vendor_payments_path, 'finance.read', 'finance/vendor_payments', 'Records'],
       ['Chart of accounts', finance_chart_of_accounts_path, 'finance.read', 'finance/chart_of_accounts', 'Records'],
       ['Ledger', ledger_index_path, 'ledger.read', 'ledger', 'Records'],
       ['Source reports', money_reconciliations_path(date: date), 'reports.read', 'money_reconciliations', 'Reports & control'],
       ['Cash forecast', cash_forecast_path(day: date), 'reports.read', 'cash_forecasts', 'Reports & control'],
       ['Business snapshot', business_snapshot_path, 'finance.read', 'business_snapshots', 'Reports & control'],
       ['Books health', books_check_path, 'reports.read', 'books_check', 'Reports & control'],
       ['Period locks', period_locks_path, 'reports.read', 'period_locks', 'Reports & control']]
    else
      []
    end
    entries.filter_map do |label, path, permission, key, group|
      allowed = permission == 'pos' ? Current.user&.can_use_pos? : retail_business_access?(permission)
      next unless allowed

      active_key = controller_path == 'inventory' && action_name == 'movements' ? 'inventory/movements' : controller_path
      [label, path, key == active_key || (key.end_with?('/*') && active_key.start_with?(key.delete_suffix('*'))), group]
    end
  end

  # "g then letter" jump keys for the Finance workspace links.
  FINANCE_SHORTCUTS = {
    'Books desk' => 'd', 'Daily reconciliation' => 'r', 'Day close' => 'c', 'Book approvals' => 'a', 'Follow-ups' => 'f',
    'Bank statements' => 'b', 'Source documents' => 's', 'Accounts' => 'o', 'Receipts' => 'p', 'Expenses' => 'e',
    'Vendor payments' => 'v', 'Chart of accounts' => 't', 'Ledger' => 'l', 'Source reports' => 'u',
    'Cash forecast' => 'w', 'Business snapshot' => 'n', 'Books health' => 'h', 'Period locks' => 'k'
  }.freeze

  # The same links split into labelled groups (Routine / Records / Reports)
  # where the workspace defines them; one unlabelled group otherwise.
  def operations_link_groups(workspace, day: nil)
    operations_links(workspace, day: day).chunk_while { |a, b| a[3] == b[3] }.map { |links| [links.first[3], links] }
  end

  def operations_workspace_page?
    controller_path.start_with?('finance/') || %w[books_desks period_locks sales inventory inventory_counts inventory_count_scans inventory_exceptions reconcile ledger financial_close business_snapshots bank_statements book_approvals books_check daily_reconciliations reconciliation_follow_ups reconciliation_documents money_reconciliations cash_forecasts].include?(controller_path)
  end

  def operations_source_name(value)
    DashboardSales::LABELS.fetch(value, value.to_s.humanize)
  end

  def operations_money(cents, currency: 'USD')
    return 'Unknown' if cents.nil?

    "#{currency.presence || 'Unknown currency'} #{number_with_precision(BigDecimal(cents.to_s) / 100, precision: 2, delimiter: ',')}"
  end
end
