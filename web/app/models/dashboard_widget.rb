# frozen_string_literal: true

# Registry of dashboard widgets. Each widget renders a partial under
# app/views/home/widgets/ and can be shown, hidden, and reordered per user.
# The per-user configuration is stored as JSON on the User record
# (dashboard_config: { "widgets" => [keys in order], "hidden" => [keys] }).
class DashboardWidget
  Widget = Struct.new(:key, :label, :partial, :position, keyword_init: true)

  WIDGETS = [
    Widget.new(key: 'stats', label: 'Key stats', partial: 'home/widgets/stats', position: 10),
    Widget.new(key: 'today_channels', label: 'Today per channel', partial: 'home/widgets/today_channels', position: 20),
    Widget.new(key: 'attention', label: 'Needs attention', partial: 'home/widgets/attention', position: 40),
    Widget.new(key: 'stock_alerts', label: 'Stock alerts · last 14 days', partial: 'home/widgets/stock_alerts',
      position: 45),
    Widget.new(key: 'revenue', label: 'Revenue · last 30 days', partial: 'home/widgets/revenue', position: 30),
    Widget.new(key: 'cash_flow', label: 'Cash flow · last 30 days', partial: 'home/widgets/cash_flow', position: 35),
    Widget.new(key: 'sync_history', label: 'Sync history', partial: 'home/widgets/sync_history', position: 60),
    Widget.new(key: 'my_tasks', label: 'My tasks', partial: 'home/widgets/my_tasks', position: 72),
    Widget.new(key: 'goals', label: 'Goals & KPIs', partial: 'home/widgets/goals', position: 75),
    Widget.new(key: 'commissions', label: 'Shift commissions · today', partial: 'home/widgets/commissions', position: 77),
    Widget.new(key: 'people', label: 'People', partial: 'home/widgets/people', position: 80)
  ].freeze

  def self.all
    WIDGETS.sort_by(&:position)
  end

  def self.find(key)
    all.find { |widget| widget.key == key.to_s }
  end

  def self.default_order
    all.map(&:key)
  end

  # Returns an array of [Widget, visible] pairs honoring a saved config hash.
  # Any registered widget missing from the config is appended in default order.
  PERMISSIONS = {
    'stats' => %w[sales.read inventory.read alerts.read],
    'today_channels' => %w[sales.read],
    'attention' => %w[inventory.read alerts.read],
    'stock_alerts' => %w[alerts.read],
    'revenue' => %w[sales.read],
    'cash_flow' => %w[finance.read],
    'sync_history' => %w[sync.read],
    'my_tasks' => %w[projects.read tasks.self],
    'goals' => %w[projects.read],
    'commissions' => %w[payroll.read],
    'people' => %w[hr.read]
  }.freeze

  def self.allowed?(key, user)
    find(key) && PERMISSIONS.fetch(key.to_s).any? { |permission| user&.can?(permission) }
  end

  def self.entries(config = {}, user: nil)
    order = Array(config['widgets']).presence || default_order
    hidden = config.key?('hidden') ? Array(config['hidden']) : ['stock_alerts']
    ordered = order.filter_map { |key| find(key) }
    ordered.concat(all.reject { |widget| order.include?(widget.key) })
    ordered.select! { |widget| allowed?(widget.key, user) } if user
    ordered.map { |widget| [widget, !hidden.include?(widget.key)] }
  end
end
