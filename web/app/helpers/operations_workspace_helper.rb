# frozen_string_literal: true

module OperationsWorkspaceHelper
  def operations_links(workspace, day: nil)
    date = day&.iso8601
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
    when :money
      [['Finance', finance_accounts_path, 'finance.read', 'finance/*'],
       ['Financial close', financial_close_path(day: date), 'reports.read', 'financial_close'],
       ['Daily checks', daily_reconciliations_path(day: date), 'reports.read', 'daily_reconciliations'],
       ['Follow-ups', reconciliation_follow_ups_path(day: date), 'reports.read', 'reconciliation_follow_ups'],
       ['Originals', reconciliation_documents_path(from: date, to: date, close_day: date), 'reports.read', 'reconciliation_documents'],
       ['Cash plan', cash_forecast_path(day: date), 'reports.read', 'cash_forecasts']]
    when :finance
      [['Accounts', finance_accounts_path, 'finance.read', 'finance/accounts'],
       ['Expenses', finance_expenses_path, 'finance.read', 'finance/expenses'],
       ['Vendor payments', finance_vendor_payments_path, 'finance.read', 'finance/vendor_payments'],
       ['Account codes', finance_chart_of_accounts_path, 'finance.read', 'finance/chart_of_accounts'],
       ['Ledger', ledger_index_path, 'ledger.read', 'ledger']]
    else
      []
    end
    entries.filter_map do |label, path, permission, key|
      allowed = permission == 'pos' ? Current.user&.can_use_pos? : retail_business_access?(permission)
      next unless allowed

      active_key = controller_path == 'inventory' && action_name == 'movements' ? 'inventory/movements' : controller_path
      [label, path, key == active_key || (key.end_with?('/*') && active_key.start_with?(key.delete_suffix('*')))]
    end
  end

  def operations_workspace_page?
    controller_path.start_with?('finance/') || %w[sales inventory inventory_counts inventory_count_scans inventory_exceptions reconcile ledger financial_close daily_reconciliations reconciliation_follow_ups reconciliation_documents money_reconciliations cash_forecasts].include?(controller_path)
  end

  def operations_source_name(value)
    DashboardSales::LABELS.fetch(value, value.to_s.humanize)
  end

  def operations_money(cents, currency: 'USD')
    return 'Unknown' if cents.nil?

    "#{currency.presence || 'Unknown currency'} #{number_with_precision(BigDecimal(cents.to_s) / 100, precision: 2, delimiter: ',')}"
  end
end
