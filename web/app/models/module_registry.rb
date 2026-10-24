# frozen_string_literal: true

# Central registry of Rupert ERP modules. New extensions register here so the
# nav, permission checks, and dashboard widgets all pick them up automatically.
#
# A module entry:
#   key:        unique string used in routes/permissions
#   name:       human label shown in the nav
#   path:       a lambda returning the route (lazy so helpers exist at call time)
#   permission: pundit-style string gate (nil = always visible)
#   position:   sort order in the nav
class ModuleRegistry
  Entry = Struct.new(:key, :name, :path, :permission, :position, keyword_init: true)

  # One entry per reachable management page (or the parent of a family of pages).
  # Labels here are the labels everywhere: rail, page eyebrow, search, dashboard.
  ENTRIES = [
    # Overview
    Entry.new(key: 'dashboard', name: 'Dashboard', path: -> { root_path }, permission: 'dashboard.read', position: 10),
    # Sell
    # The full-screen cashier sits above Sales; the section's rail link still opens Sales
    # (ApplicationHelper#area_landing_entry) so "Sell" never leaves the management shell.
    Entry.new(key: 'ctrax_pos', name: 'POS', path: -> { ctrax_pos_path }, permission: %w[sales.read sales.write inventory.read], position: 19),
    Entry.new(key: 'sales', name: 'Sales', path: -> { sales_path }, permission: 'sales.read', position: 20),
    Entry.new(key: 'registers', name: 'Registers', path: -> { sales_pos_sessions_path }, permission: 'sales.read', position: 22),
    Entry.new(key: 'ctrax_days', name: 'C-Trax daily close', path: -> { ctrax_days_path }, permission: 'sales.read', position: 24),
    Entry.new(key: 'swipesimple_days', name: 'SwipeSimple daily close', path: -> { swipesimple_days_path }, permission: 'sales.read', position: 24.5),
    Entry.new(key: 'customers', name: 'Customers', path: -> { customers_path }, permission: 'customers.read', position: 30),
    # Marketing
    Entry.new(key: 'marketing', name: 'Marketing', path: -> { marketing_path }, permission: 'marketing.read', position: 35),
    Entry.new(key: 'influencers', name: 'Influencers', path: -> { marketing_influencers_path }, permission: 'marketing.read', position: 36),
    # Stock
    Entry.new(key: 'inventory', name: 'Inventory', path: -> { inventory_index_path }, permission: 'inventory.read', position: 40),
    Entry.new(key: 'stock_comparison', name: 'Store comparison', path: -> { stock_comparison_path }, permission: 'inventory.read', position: 40.1),
    Entry.new(key: 'movements', name: 'Movements', path: -> { movements_inventory_index_path }, permission: 'inventory.read', position: 40.2),
    Entry.new(key: 'product_names', name: 'Product names', path: -> { product_names_path }, permission: 'inventory.read', position: 40.3),
    Entry.new(key: 'inventory_exceptions', name: 'Stock review', path: -> { inventory_exceptions_path }, permission: 'inventory.read', position: 41),
    Entry.new(key: 'inventory_counts', name: 'Physical counts', path: -> { inventory_counts_path }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'stock_requests', name: 'Transfers & backorders', path: -> { stock_requests_path }, permission: 'inventory.read', position: 44.1),
    Entry.new(key: 'stock_reservations', name: 'Reservations', path: -> { stock_reservations_path }, permission: 'inventory.read', position: 44.2),
    Entry.new(key: 'alerts', name: 'Stock alerts', path: -> { alerts_path }, permission: 'alerts.read', position: 44.3),
    Entry.new(key: 'bulk_materials', name: 'Bulk materials', path: -> { bulk_materials_path }, permission: 'inventory.read', position: 44.4),
    Entry.new(key: 'bulk_recipes', name: 'Bulk recipes', path: -> { bulk_recipes_path }, permission: 'inventory.read', position: 44.5),
    Entry.new(key: 'bulk_consumptions', name: 'Material use', path: -> { bulk_consumptions_path }, permission: 'inventory.read', position: 44.6),
    Entry.new(key: 'purchase_orders', name: 'Purchase orders', path: -> { purchasing_purchase_orders_path }, permission: 'purchasing.read', position: 46),
    Entry.new(key: 'vendors', name: 'Vendors', path: -> { purchasing_vendors_path }, permission: 'purchasing.read', position: 45),
    Entry.new(key: 'reconcile', name: 'Catalog links', path: -> { reconcile_index_path }, permission: 'reconcile.read', position: 50),
    Entry.new(key: 'swipesimple_items', name: 'SwipeSimple items', path: -> { swipesimple_items_path }, permission: 'inventory.read', position: 50.1),
    Entry.new(key: 'sizes', name: 'Sizes', path: -> { size_families_path }, permission: 'settings.read', position: 51),
    Entry.new(key: 'locations', name: 'Locations', path: -> { locations_path }, permission: 'inventory.read', position: 42),
    Entry.new(key: 'warehouse', name: 'Warehouse sales', path: -> { warehouse_path }, permission: 'settings.read', position: 43),
    # Bookkeeping
    Entry.new(key: 'bookkeeping', name: 'Bookkeeping', path: -> { bookkeeping_path }, permission: 'finance.read', position: 45),
    Entry.new(key: 'cash_flow', name: 'Cash flow', path: -> { finance_cash_flow_path }, permission: 'finance.read', position: 45.1),
    Entry.new(key: 'business_snapshot', name: 'Business snapshot', path: -> { business_snapshot_path }, permission: 'finance.read', position: 61),
    Entry.new(key: 'books_check', name: 'Books health', path: -> { books_check_path }, permission: 'reports.read', position: 62),
    Entry.new(key: 'financial_close', name: 'Day close', path: -> { financial_close_path }, permission: 'reports.read', position: 55),
    Entry.new(key: 'daily_reconciliation', name: 'Daily reconciliation', path: -> { daily_reconciliations_path }, permission: 'reports.read', position: 56),
    Entry.new(key: 'register_summary', name: 'Register summary', path: -> { register_summary_reports_path }, permission: 'reports.read', position: 56.1),
    Entry.new(key: 'reconciliation_overview', name: 'Open days', path: -> { overview_reconciliation_follow_ups_path }, permission: 'reports.read', position: 58),
    Entry.new(key: 'reconciliation_follow_ups', name: 'Follow-ups', path: -> { reconciliation_follow_ups_path }, permission: 'reports.read', position: 59),
    Entry.new(key: 'reconciliation_documents', name: 'Source documents', path: -> { reconciliation_documents_path }, permission: 'reports.read', position: 58.1),
    Entry.new(key: 'books_desk', name: 'Close & review', path: -> { books_desk_path }, permission: 'reports.read', position: 46),
    Entry.new(key: 'book_approvals', name: 'Book approvals', path: -> { book_approvals_path }, permission: 'reports.read', position: 57),
    Entry.new(key: 'period_locks', name: 'Period locks', path: -> { period_locks_path }, permission: 'reports.read', position: 63),
    Entry.new(key: 'bank_statements', name: 'Bank transactions', path: -> { bank_statements_path }, permission: 'finance.read', position: 60),
    Entry.new(key: 'bank_reconciliation', name: 'Bank reconciliation', path: -> { finance_bank_reconciliation_path }, permission: 'finance.read', position: 53),
    Entry.new(key: 'source_reports', name: 'Source reports', path: -> { money_reconciliations_path }, permission: 'reports.read', position: 64),
    Entry.new(key: 'swipesimple_reports', name: 'SwipeSimple reports', path: -> { swipesimple_reports_path }, permission: 'reports.read', position: 64.1),
    Entry.new(key: 'zelle_reports', name: 'Zelle reports', path: -> { zelle_reports_path }, permission: 'reports.read', position: 64.2),
    Entry.new(key: 'retention_drive', name: 'Drive copies', path: -> { retention_drive_path }, permission: 'reports.read', position: 57.1),
    Entry.new(key: 'ledger', name: 'Imported orders', path: -> { ledger_index_path }, permission: 'ledger.read', position: 60),
    Entry.new(key: 'journal_entries', name: 'General ledger', path: -> { finance_journal_entries_path }, permission: 'finance.read', position: 51),
    Entry.new(key: 'chart_of_accounts', name: 'Chart of accounts', path: -> { finance_chart_of_accounts_path }, permission: 'finance.read', position: 48),
    Entry.new(key: 'finance_accounts', name: 'Accounts', path: -> { finance_accounts_path }, permission: 'finance.read', position: 47),
    Entry.new(key: 'expenses', name: 'Expenses', path: -> { finance_expenses_path }, permission: 'finance.read', position: 49),
    Entry.new(key: 'expense_categories', name: 'Expense categories', path: -> { finance_expense_categories_path }, permission: 'finance.read', position: 49.1),
    Entry.new(key: 'payments', name: 'Vendor payments', path: -> { finance_vendor_payments_path }, permission: 'finance.read', position: 50),
    Entry.new(key: 'payees', name: 'By payee', path: -> { finance_payees_path }, permission: 'finance.read', position: 50.1),
    Entry.new(key: 'finance_history', name: 'History', path: -> { finance_history_path }, permission: 'finance.read', position: 50.2),
    Entry.new(key: 'quickbooks_imports', name: 'QuickBooks import', path: -> { finance_quickbooks_imports_path }, permission: 'finance.read', position: 50.3),
    Entry.new(key: 'ledger_export', name: 'Export ledger', path: -> { finance_ledger_export_path }, permission: 'finance.read', position: 54),
    Entry.new(key: 'cash_forecast', name: 'Cash forecast', path: -> { cash_forecast_path }, permission: 'reports.read', position: 60),
    # Reports
    Entry.new(key: 'reports', name: 'All reports', path: -> { reports_path }, permission: 'reports.read', position: 55),
    Entry.new(key: 'sales_tax', name: 'Sales tax', path: -> { sales_tax_reports_path }, permission: 'reports.read', position: 55),
    Entry.new(key: 'finance_reports', name: 'Financial statements', path: -> { finance_reports_path }, permission: 'finance.read', position: 52),
    # Work
    Entry.new(key: 'projects', name: 'Projects', path: -> { projects_projects_path }, permission: 'projects.read', position: 70),
    Entry.new(key: 'tasks', name: 'Tasks', path: -> { projects_tasks_path }, permission: 'projects.read', position: 71),
    Entry.new(key: 'goals', name: 'Goals', path: -> { goals_goals_path }, permission: 'projects.read', position: 75),
    Entry.new(key: 'kpis', name: 'KPIs', path: -> { goals_kpis_path }, permission: 'projects.read', position: 78),
    # Me
    Entry.new(key: 'receipts', name: 'My receipts', path: -> { receipts_path }, permission: nil, position: 54),
    Entry.new(key: 'time_clock', name: 'Time clock', path: -> { time_clock_path }, permission: nil, position: 87.4),
    Entry.new(key: 'learning', name: 'Learn Rupert', path: -> { learning_index_path }, permission: nil, position: 89),
    # Team
    Entry.new(key: 'employees', name: 'Staff', path: -> { people_employees_path }, permission: 'hr.read', position: 85),
    Entry.new(key: 'team_chat', name: 'Team chat', path: -> { team_chat_path }, permission: 'settings.write', position: 85.5),
    Entry.new(key: 'accounts', name: 'Users', path: -> { users_path }, permission: 'users.read', position: 84),
    Entry.new(key: 'permissions', name: 'Permissions', path: -> { permissions_path }, permission: 'users.read', position: 92),
    Entry.new(key: 'departments', name: 'Departments', path: -> { people_departments_path }, permission: 'hr.read', position: 86),
    Entry.new(key: 'positions', name: 'Positions', path: -> { people_positions_path }, permission: 'hr.read', position: 87),
    Entry.new(key: 'time_keeping', name: 'Time keeping', path: -> { people_time_keeping_path }, permission: 'timesheets.read', position: 87),
    Entry.new(key: 'timesheets', name: 'Timesheets', path: -> { people_timesheets_path }, permission: 'timesheets.self', position: 87.5),
    Entry.new(key: 'punch_history', name: 'Punch report', path: -> { people_punch_history_path }, permission: 'timesheets.read', position: 88),
    Entry.new(key: 'square_timesheets', name: 'Square history', path: -> { people_square_timesheets_path }, permission: 'timesheets.read', position: 88.1),
    Entry.new(key: 'ctrax_timesheets', name: 'C-Trax history', path: -> { people_ctrax_timesheets_path }, permission: 'timesheets.read', position: 88.2),
    Entry.new(key: 'schedule', name: 'Shifts', path: -> { people_scheduled_shifts_path }, permission: 'hr.read', position: 88),
    Entry.new(key: 'team_schedule', name: 'Team schedule', path: -> { people_team_schedule_path }, permission: 'timesheets.read', position: 88.3),
    Entry.new(key: 'leave', name: 'Leave & PTO', path: -> { people_leave_requests_path }, permission: 'leave.read', position: 89),
    Entry.new(key: 'payroll', name: 'Payroll', path: -> { people_pay_runs_path }, permission: 'payroll.read', position: 90),
    Entry.new(key: 'incentives', name: 'Incentives model', path: -> { people_incentives_path }, permission: 'payroll.read', position: 90.5),
    Entry.new(key: 'employee_reports', name: 'Staff reports', path: -> { people_work_reports_path }, permission: 'hr.read', position: 86),
    Entry.new(key: 'training', name: 'Training progress', path: -> { learning_team_path }, permission: 'hr.read', position: 86.5),
    # System
    Entry.new(key: 'system', name: 'System health', path: -> { system_path }, permission: 'system.read', position: 95),
    Entry.new(key: 'platform', name: 'Instance overview', path: -> { platform_path }, permission: nil, position: 89),
    Entry.new(key: 'activity', name: 'Activity', path: -> { activity_path }, permission: 'settings.read', position: 82),
    Entry.new(key: 'access_log', name: 'Access log', path: -> { access_logs_path }, permission: 'settings.read', position: 81),
    Entry.new(key: 'connections', name: 'Credentials & sync', path: -> { connections_path }, permission: 'settings.read', position: 94),
    Entry.new(key: 'pos_connections', name: 'POS & payments', path: -> { pos_connections_path }, permission: 'settings.read', position: 94),
    Entry.new(key: 'sync', name: 'Sync', path: -> { syncs_path }, permission: 'sync.read', position: 90),
    Entry.new(key: 'uploads', name: 'Uploads', path: -> { uploads_path }, permission: 'uploads.read', position: 90.5),
    Entry.new(key: 'settings', name: 'Settings', path: -> { settings_path }, permission: 'settings.read', position: 100),
    Entry.new(key: 'api_access_tokens', name: 'API access', path: -> { api_access_tokens_path }, permission: 'settings.write', position: 108),
    Entry.new(key: 'agent_feedback', name: 'AI assistant feedback', path: -> { agent_feedbacks_path }, permission: 'settings.read', position: 108),
    Entry.new(key: 'ask_rupert_usage', name: 'Ask Rupert usage', path: -> { ask_rupert_usage_path }, permission: 'settings.read', position: 108.5),
    Entry.new(key: 'owner_checklists', name: 'Owner checklists', path: -> { owner_checklists_path }, permission: nil, position: 109),
    Entry.new(key: 'roadmap', name: 'Features & roadmap', path: -> { roadmap_path }, permission: nil, position: 110),
    Entry.new(key: 'style_guide', name: 'Style guide', path: -> { system_style_guide_path }, permission: 'settings.read', position: 111)
  ].freeze

  class << self
    def all
      ENTRIES
    end

    # Nav entries visible to a user, sorted by position.
    def nav_for(user)
      return [] unless user&.active?

      if user.employee?
        return all.select { |entry| %w[ctrax_pos time_clock timesheets receipts learning].include?(entry.key) }.sort_by(&:position)
      end

      all.select do |entry|
        next user.can_use_pos? if %w[ctrax_pos point_of_sale].include?(entry.key)
        next false if %w[platform system].include?(entry.key) && !user.super_admin?
        next false if entry.key == 'employee_reports' && !user.can_manage_accounts?
        next user.can?('hr.read') || user.can?('schedule.write') if entry.key == 'schedule'
        next false if entry.key == 'owner_checklists' && !(user&.active? && (user.admin? || user.super_admin?))

        next false if entry.key == 'influencers' && !FeatureFlag.enabled?(:marketing)
        next false if entry.key == 'marketing' && !FeatureFlag.enabled?(:marketing) && !user.can_manage_accounts?

        Array(entry.permission).all? { |permission| user.can?(permission) }
      end.sort_by(&:position)
    end

    def find(key)
      all.find { |e| e.key == key.to_s }
    end

    # Top-level ERP areas that group modules in the header. "modules" lists the
    # entry keys that belong to the area, in display order. Areas follow the
    # operator's day (sell / stock / money / work / team), not the org chart.
    # Every registered module must appear in exactly one area.
    AREAS = [
      { key: 'overview', name: 'Overview', modules: ['dashboard'] },
      { key: 'sell', name: 'Sell',
        modules: %w[ctrax_pos sales registers ctrax_days swipesimple_days customers],
        groups: [
          { name: 'Sales & POS', modules: %w[ctrax_pos sales registers] },
          { name: 'Daily close', modules: %w[ctrax_days swipesimple_days] },
          { name: 'Customers', modules: %w[customers] }
        ] },
      { key: 'marketing', name: 'Marketing', modules: %w[marketing influencers] },
      { key: 'stock', name: 'Stock',
        modules: %w[inventory stock_comparison movements product_names inventory_exceptions alerts
                    inventory_counts stock_requests stock_reservations
                    bulk_materials bulk_recipes bulk_consumptions
                    purchase_orders vendors
                    reconcile swipesimple_items sizes locations warehouse],
        groups: [
          { name: 'Stock', modules: %w[inventory stock_comparison movements product_names inventory_exceptions alerts] },
          { name: 'Counts & requests', modules: %w[inventory_counts stock_requests stock_reservations] },
          { name: 'Materials', modules: %w[bulk_materials bulk_recipes bulk_consumptions] },
          { name: 'Purchasing', modules: %w[purchase_orders vendors] },
          { name: 'Catalog & places', modules: %w[reconcile swipesimple_items sizes locations warehouse] }
        ] },
      { key: 'money', name: 'Bookkeeping',
        modules: %w[bookkeeping cash_flow business_snapshot books_check
                    financial_close daily_reconciliation register_summary reconciliation_overview reconciliation_follow_ups reconciliation_documents
                    books_desk book_approvals period_locks bank_statements bank_reconciliation source_reports swipesimple_reports zelle_reports retention_drive
                    ledger journal_entries chart_of_accounts finance_accounts expenses expense_categories payments payees finance_history quickbooks_imports ledger_export
                    cash_forecast],
        # Display order is group order; every module of the area appears in exactly one group.
        groups: [
          { name: 'Overview', modules: %w[bookkeeping cash_flow business_snapshot books_check] },
          { name: 'Daily close', modules: %w[financial_close daily_reconciliation register_summary reconciliation_overview reconciliation_follow_ups reconciliation_documents] },
          { name: 'Books & review', modules: %w[books_desk book_approvals period_locks bank_statements bank_reconciliation source_reports swipesimple_reports zelle_reports retention_drive] },
          { name: 'Ledger & accounts', modules: %w[ledger journal_entries chart_of_accounts finance_accounts expenses expense_categories payments payees finance_history quickbooks_imports ledger_export] },
          { name: 'Planning', modules: %w[cash_forecast] }
        ] },
      # Every report in one place; each report page also carries the same tab bar.
      { key: 'reports', name: 'Reports', modules: %w[reports sales_tax finance_reports] },
      { key: 'work', name: 'Work', modules: %w[projects tasks goals kpis] },
      # Personal staff self-service (own receipts, own hours). Receipts has no permission, so
      # this area is visible to everyone.
      { key: 'me', name: 'Me', modules: %w[receipts time_clock learning] },
      { key: 'team', name: 'Team',
        modules: %w[employees team_chat accounts permissions departments positions
                    time_keeping timesheets punch_history square_timesheets ctrax_timesheets schedule team_schedule leave
                    payroll incentives employee_reports training],
        groups: [
          { name: 'People', modules: %w[employees team_chat accounts permissions departments positions] },
          { name: 'Time', modules: %w[time_keeping timesheets punch_history square_timesheets ctrax_timesheets schedule team_schedule leave] },
          { name: 'Pay & reports', modules: %w[payroll incentives employee_reports training] }
        ] },
      { key: 'system', name: 'System',
        modules: %w[system platform activity access_log
                    connections pos_connections sync uploads
                    settings api_access_tokens agent_feedback ask_rupert_usage owner_checklists roadmap style_guide],
        groups: [
          { name: 'Health', modules: %w[system platform activity access_log] },
          { name: 'Connections', modules: %w[connections pos_connections sync uploads] },
          { name: 'Settings', modules: %w[settings api_access_tokens agent_feedback ask_rupert_usage owner_checklists roadmap style_guide] }
        ] }
    ].freeze

    # Sub-sections of an area with only the visible modules; empty groups drop out.
    def groups_for(area, modules)
      Array(area[:groups]).filter_map do |group|
        entries = group[:modules].filter_map { |key| modules.find { |entry| entry.key == key } }
        { name: group[:name], modules: entries } if entries.any?
      end
    end

    def area_key_for(module_key)
      AREAS.find { |area| area[:modules].include?(module_key.to_s) }&.dig(:key)
    end

    # Areas with their modules filtered by the user's permissions.
    def areas_for(user, visible: nil)
      visible ||= nav_for(user)
      # Staff members get one personal section with everything they can open.
      return [{ key: 'me', name: 'Me', modules: visible, groups: [] }] if user&.employee? && visible.any?

      AREAS.filter_map do |area|
        modules = area[:modules].filter_map { |key| visible.find { |entry| entry.key == key } }
        next if modules.empty?
        # Features & roadmap stays in the account menu when it is the only System page.
        next if area[:key] == 'system' && modules.all? { |entry| entry.key == 'roadmap' }

        { key: area[:key], name: area[:name], modules: modules, groups: groups_for(area, modules) }
      end
    end
  end
end
