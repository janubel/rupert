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

  ENTRIES = [
    Entry.new(key: 'marketing', name: 'Marketing', path: -> { marketing_path }, permission: 'marketing.read', position: 35),
    Entry.new(key: 'roadmap', name: 'Features & roadmap', path: -> { roadmap_path }, permission: nil, position: 110),
    Entry.new(key: 'owner_checklists', name: 'Owner checklists', path: -> { owner_checklists_path }, permission: nil, position: 109),
    Entry.new(key: 'api_access_tokens', name: 'API access', path: lambda {
      api_access_tokens_path
    }, permission: 'settings.write', position: 108),
    Entry.new(key: 'dashboard', name: 'Dashboard', path: -> { root_path }, permission: 'dashboard.read', position: 10),
    Entry.new(key: 'platform', name: 'Instance overview', path: -> { platform_path }, permission: nil, position: 89),
    Entry.new(key: 'sales', name: 'Sales', path: -> { sales_path }, permission: 'sales.read', position: 20),
    Entry.new(key: 'ctrax_pos', name: 'C-Trax retail', path: -> { ctrax_pos_path }, permission: %w[sales.read sales.write inventory.read], position: 21),
    Entry.new(key: 'ctrax_days', name: 'C-Trax daily close', path: -> { ctrax_days_path }, permission: 'sales.read', position: 24),
    Entry.new(key: 'point_of_sale', name: 'POS preview', path: lambda {
      point_of_sale_path
    }, permission: %w[sales.read sales.write inventory.read], position: 22),
    Entry.new(key: 'registers', name: 'Registers', path: lambda {
      sales_pos_sessions_path
    }, permission: 'sales.read', position: 25),
    Entry.new(key: 'customers', name: 'Customers', path: lambda {
      customers_path
    }, permission: 'customers.read', position: 30),
    Entry.new(key: 'inventory', name: 'Inventory', path: lambda {
      inventory_index_path
    }, permission: 'inventory.read', position: 40),
    Entry.new(key: 'inventory_exceptions', name: 'Inventory review', path: lambda {
      inventory_exceptions_path
    }, permission: 'inventory.read', position: 41),
    Entry.new(key: 'bulk_recipes', name: 'Bulk recipes', path: lambda {
      bulk_recipes_path
    }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'bulk_consumptions', name: 'Sale material use', path: lambda {
      bulk_consumptions_path
    }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'locations', name: 'Locations', path: lambda {
      locations_path
    }, permission: 'inventory.read', position: 42),
    Entry.new(key: 'inventory_counts', name: 'Counts', path: lambda {
      inventory_counts_path
    }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'stock_reservations', name: 'Reservations', path: lambda {
      stock_reservations_path
    }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'bulk_materials', name: 'Bulk materials', path: lambda {
      bulk_materials_path
    }, permission: 'inventory.read', position: 44),
    Entry.new(key: 'warehouse', name: 'Warehouse', path: lambda {
      warehouse_path
    }, permission: 'settings.read', position: 43),
    Entry.new(key: 'reconcile', name: 'Catalog Links', path: lambda {
      reconcile_index_path
    }, permission: 'reconcile.read', position: 50),
    Entry.new(key: 'sizes', name: 'Sizes', path: -> { size_families_path }, permission: 'settings.read', position: 51),
    Entry.new(key: 'reports', name: 'Reports', path: -> { reports_path }, permission: 'reports.read', position: 55),
    Entry.new(key: 'daily_reconciliation', name: 'Daily reconciliation & documents', path: -> { daily_reconciliations_path }, permission: 'reports.read', position: 56),
    Entry.new(key: 'register_summary', name: 'Daily register summary', path: lambda {
      register_summary_reports_path
    }, permission: 'reports.read', position: 56),
    Entry.new(key: 'time_clock', name: 'Time clock', path: -> { time_clock_path }, permission: nil, position: 88),
    Entry.new(key: 'ledger', name: 'Ledger', path: -> { ledger_index_path }, permission: 'ledger.read', position: 60),
    Entry.new(key: 'projects', name: 'Projects', path: lambda {
      projects_projects_path
    }, permission: 'projects.read', position: 70),
    Entry.new(key: 'tasks', name: 'Tasks', path: -> { projects_tasks_path }, permission: 'projects.read', position: 71),
    Entry.new(key: 'goals', name: 'Goals', path: -> { goals_goals_path }, permission: 'projects.read', position: 75),
    Entry.new(key: 'kpis', name: 'KPIs', path: -> { goals_kpis_path }, permission: 'projects.read', position: 78),
    Entry.new(key: 'alerts', name: 'Alerts', path: -> { alerts_path }, permission: 'alerts.read', position: 80),
    Entry.new(key: 'activity', name: 'Activity', path: -> { activity_path }, permission: 'settings.read', position: 82),
    Entry.new(key: 'access_log', name: 'Access log', path: lambda {
      access_logs_path
    }, permission: 'settings.read', position: 81),
    Entry.new(key: 'sync', name: 'Sync', path: -> { syncs_path }, permission: 'sync.read', position: 90),
    Entry.new(key: 'system', name: 'System', path: -> { system_path }, permission: 'system.read', position: 95),
    Entry.new(key: 'pos_connections', name: 'POS & payments', path: lambda {
      pos_connections_path
    }, permission: 'settings.read', position: 94),
    Entry.new(key: 'connections', name: 'Connections', path: lambda {
      connections_path
    }, permission: 'settings.read', position: 94),
    Entry.new(key: 'settings', name: 'Settings', path: lambda {
      settings_path
    }, permission: 'settings.read', position: 100),
    Entry.new(key: 'employees', name: 'Employees', path: lambda {
      people_employees_path
    }, permission: 'hr.read', position: 85),
    Entry.new(key: 'departments', name: 'Departments', path: lambda {
      people_departments_path
    }, permission: 'hr.read', position: 86),
    Entry.new(key: 'positions', name: 'Positions', path: lambda {
      people_positions_path
    }, permission: 'hr.read', position: 87),
    Entry.new(key: 'timesheets', name: 'Timesheets', path: lambda {
      people_timesheets_path
    }, permission: 'timesheets.read', position: 88),
    Entry.new(key: 'leave', name: 'Leave & PTO', path: lambda {
      people_leave_requests_path
    }, permission: 'leave.read', position: 89),
    Entry.new(key: 'payroll', name: 'Payroll', path: lambda {
      people_pay_runs_path
    }, permission: 'payroll.read', position: 90),
    Entry.new(key: 'accounts', name: 'Users', path: -> { users_path }, permission: 'users.read', position: 84),
    Entry.new(key: 'permissions', name: 'Permissions', path: lambda {
      permissions_path
    }, permission: 'users.read', position: 92),
    Entry.new(key: 'vendors', name: 'Vendors', path: lambda {
      purchasing_vendors_path
    }, permission: 'purchasing.read', position: 45),
    Entry.new(key: 'purchase_orders', name: 'Purchase orders', path: lambda {
      purchasing_purchase_orders_path
    }, permission: 'purchasing.read', position: 46),
    Entry.new(key: 'finance_accounts', name: 'Accounts', path: lambda {
      finance_accounts_path
    }, permission: 'finance.read', position: 47),
    Entry.new(key: 'chart_of_accounts', name: 'Chart of accounts', path: lambda {
      finance_chart_of_accounts_path
    }, permission: 'finance.read', position: 48),
    Entry.new(key: 'expenses', name: 'Expenses', path: lambda {
      finance_expenses_path
    }, permission: 'finance.read', position: 49),
    Entry.new(key: 'payments', name: 'Payments', path: lambda {
      finance_vendor_payments_path
    }, permission: 'finance.read', position: 50)
  ].freeze

  class << self
    def all
      ENTRIES
    end

    # Nav entries visible to a user, sorted by position.
    def nav_for(user)
      return [] unless user&.active?

      all.select do |entry|
        next false if %w[platform system].include?(entry.key) && !user.super_admin?
        next false if entry.key == 'owner_checklists' && !(user&.active? && (user.admin? || user.super_admin?))

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
      { key: 'sell', name: 'Sell', modules: %w[sales ctrax_pos point_of_sale ctrax_days registers customers] },
      { key: 'marketing', name: 'Marketing', modules: %w[marketing] },
      { key: 'stock', name: 'Stock',
        modules: %w[inventory inventory_exceptions locations inventory_counts stock_reservations bulk_materials bulk_recipes bulk_consumptions alerts purchase_orders vendors reconcile sizes] },
      { key: 'money', name: 'Money',
        modules: %w[reports daily_reconciliation register_summary ledger finance_accounts chart_of_accounts expenses payments] },
      { key: 'work', name: 'Work', modules: %w[projects tasks goals kpis] },
      { key: 'team', name: 'Team',
        modules: %w[accounts employees departments positions time_clock timesheets leave payroll permissions] },
      { key: 'system', name: 'System',
        modules: %w[system platform connections pos_connections sync settings warehouse activity access_log api_access_tokens roadmap owner_checklists] }
    ].freeze

    def area_key_for(module_key)
      AREAS.find { |area| area[:modules].include?(module_key.to_s) }&.dig(:key)
    end

    # Areas with their modules filtered by the user's permissions.
    def areas_for(user)
      visible = nav_for(user)
      AREAS.filter_map do |area|
        modules = visible.select { |entry| area[:modules].include?(entry.key) }
        next if modules.empty?
        # Personal time and help remain in the account menu when they are the
        # only destinations in an otherwise unavailable staff/admin area.
        next if area[:key] == 'team' && modules.all? { |entry| entry.key == 'time_clock' }
        next if area[:key] == 'system' && modules.all? { |entry| entry.key == 'roadmap' }

        { key: area[:key], name: area[:name], modules: modules }
      end
    end
  end
end
