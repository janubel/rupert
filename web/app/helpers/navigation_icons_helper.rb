# frozen_string_literal: true

# Small local outline icons. Names remain in the UI or accessible control label.
module NavigationIconsHelper
  NAV_ICON_PATHS = {
    'overview' => ['M3 10 12 3l9 7v10H3Z', 'M9 20v-7h6v7'],
    'sell' => ['M3 4h2l3 12h11l2-8H6', 'M9 20h.01M18 20h.01'],
    'stock' => ['M3 7 12 3l9 4v10l-9 4-9-4Z', 'm3 7 9 4 9-4M12 11v10'],
    'money' => ['M3 5h18v14H3Z', 'M3 9h18M7 15h4M16 15h1'],
    'work' => ['M9 5V3h6v2M3 5h18v15H3Z', 'M3 10c6 4 12 4 18 0M12 10v4'],
    'team' => ['M8 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z', 'M1 21v-2a7 7 0 0 1 14 0v2M17 4a4 4 0 0 1 0 8M18 15a6 6 0 0 1 5 6'],
    'system' => ['M4 4h16v6H4ZM4 14h16v6H4Z', 'M7 7h.01M7 17h.01M11 7h6M11 17h6'],
    'search' => ['M10 17a7 7 0 1 0 0-14 7 7 0 0 0 0 14Z', 'm15 15 6 6'],
    'sync' => ['M20 7a9 9 0 0 0-16-2M4 3v5h5', 'M4 17a9 9 0 0 0 16 2M20 21v-5h-5'],
    'platform' => ['M3 3h7v7H3ZM14 3h7v7h-7ZM3 14h7v7H3ZM14 14h7v7h-7Z'],
    'tools' => ['M4 6h16M4 12h16M4 18h16', 'M8 3v6M16 9v6M10 15v6'],
    'clock' => ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z', 'M12 7v5l3 2'],
    'chevron' => ['m6 9 6 6 6-6'],
    'check' => ['m4 12 5 5L20 6'],
    'logout' => ['M9 3H3v18h6M13 7l5 5-5 5M7 12h14'],
    'count' => ['M5 3v18M9 3v18M13 3v18M17 3v18M21 3v18'],
    'review' => ['M8 3h13v18H3V8Z', 'm7 12 3 3 6-6'],
    'link' => ['m9 15 6-6M8 17l-2 2a4 4 0 0 1-5-5l5-5a4 4 0 0 1 5 0', 'm16 7 2-2a4 4 0 0 1 5 5l-5 5a4 4 0 0 1-5 0'],
    'report' => ['M4 3h16v18H4Z', 'M8 16v-3M12 16V8M16 16v-5'],
    'alert' => ['m12 3 10 18H2Z', 'M12 9v5M12 17h.01'],
    'settings' => ['M4 6h16M4 12h16M4 18h16', 'M8 3v6M16 9v6M10 15v6'],
    'document' => ['M5 3h10l4 4v14H5Z', 'M14 3v5h5M8 12h8M8 16h8'],
    'shield' => ['m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6Z', 'm8 12 3 3 5-6']
  }.freeze

  MODULE_ICON_KEYS = {
    'dashboard' => 'overview', 'point_of_sale' => 'sell', 'inventory_counts' => 'count',
    'inventory_exceptions' => 'review', 'bulk_consumptions' => 'review', 'reconcile' => 'link',
    'connections' => 'link', 'pos_connections' => 'link', 'alerts' => 'alert',
    'reports' => 'report', 'register_summary' => 'report', 'time_clock' => 'clock',
    'settings' => 'settings', 'platform' => 'platform', 'owner_checklists' => 'review',
    'api_access_tokens' => 'shield', 'permissions' => 'shield', 'roadmap' => 'document'
  }.freeze

  def navigation_icon(key, css_class: 'nav-symbol')
    paths = NAV_ICON_PATHS.fetch(key.to_s, NAV_ICON_PATHS.fetch('document'))
    tag.svg(viewBox: '0 0 24 24', width: 20, height: 20, fill: 'none', stroke: 'currentColor',
      'stroke-width': 1.7, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
      'aria-hidden': true, focusable: false, class: css_class) do
      safe_join(paths.map { |path| tag.path(d: path) })
    end
  end

  def module_icon_key(entry)
    MODULE_ICON_KEYS.fetch(entry.key, ModuleRegistry.area_key_for(entry.key) || 'document')
  end

  def navigation_role_name(user)
    { 'super_admin' => 'Platform administrator', 'admin' => 'Store administrator',
      'manager' => 'Manager', 'cashier' => 'Cashier', 'inventory_employee' => 'Inventory staff',
      'reporting' => 'Reporting', 'reader' => 'Reader' }.fetch(user.role, user.role.to_s.humanize)
  end
end
