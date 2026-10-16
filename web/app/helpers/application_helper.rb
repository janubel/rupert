# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend

  # --- Module-area navigation helpers (see ModuleRegistry) ---

  def nav_areas
    @nav_areas ||= ModuleRegistry.areas_for(Current.user)
  end

  # Safely evaluate a module's lazy path; "#" keeps the nav alive if a route
  # helper is missing (e.g. mid-development).
  def safe_module_path(entry)
    instance_exec(&entry.path)
  rescue StandardError
    '#'
  end

  def module_match_strength(path)
    return 0 if path.blank? || path == '#'

    return request.path == '/' ? 100 : 0 if path == '/'

    return path.length if request.path == path
    return path.length if request.path.start_with?("#{path}/")

    0
  end

  def active_module_entry
    @active_module_entry ||= ModuleRegistry.nav_for(Current.user)
      .select { |entry| module_match_strength(safe_module_path(entry)).positive? }
      .max_by { |entry| module_match_strength(safe_module_path(entry)) }
  end

  def navigation_start_path
    entry = ModuleRegistry.nav_for(Current.user).first
    entry ? safe_module_path(entry) : root_path
  end

  def active_area_key
    @active_area_key ||= ModuleRegistry.area_key_for(active_module_entry&.key) ||
                         nav_areas.first&.dig(:key)
  end

  def active_area_modules
    nav_areas.find { |area| area[:key] == active_area_key }&.dig(:modules) || []
  end

  # Chart palette derived from the Tailwind @theme tokens in
  # app/assets/tailwind/application.css. Keep the two in sync.
  CHART_COLORS = {
    ink: '#1a393d',
    olive_deep: '#108184',
    clay: '#7d5449',
    butter: '#e4be58',
    rose: '#b05b4f',
    sage: '#5c8a72',
    fern: '#2e7d64'
  }.freeze

  def chart_color(*keys)
    keys.map { |key| CHART_COLORS.fetch(key) }
  end

  def vs_yesterday(today_cents, yesterday_cents)
    return 'vs yesterday' if today_cents.nil? || yesterday_cents.nil? || yesterday_cents.zero?

    delta = today_cents - yesterday_cents
    pct = (delta.to_f / yesterday_cents * 100).round
    "#{pct.positive? ? '+' : ''}#{pct}% vs yesterday"
  end

  def attention_items(presenter)
    items = []
    mismatches = presenter.sku_mismatches

    if mismatches.positive?
      items << {
        label: "#{mismatches} SKU mismatches",
        note: 'Same item, different SKU per platform — review on Catalog Links',
        value: mismatches.to_s,
        pill: 'pill-clay'
      }
    end

    presenter.recent_alerts.each do |alert|
      break if items.length >= 5

      items << {
        label: alert.sku.presence || alert.id.first(10),
        note: "Low stock · #{alert.quantity} left / threshold #{alert.threshold}",
        value: alert.quantity <= 0 ? 'out' : 'low',
        pill: alert.quantity <= 0 ? 'pill-rose' : 'pill-clay'
      }
    end

    items
  end

  # Fragment cache keyed on the tenant's data version so the fragment is served
  # until the next sync/mutation invalidates it. Only wrap content with no
  # per-session forms (CSRF tokens can't be cached).
  def cached_fragment(name, **params, &block)
    cache(['page', Current.tenant_id, name, DataCache.version, params].compact, &block)
  end

  def time_based_greeting
    case Time.current.hour
    when 0...12 then 'Good morning'
    when 12...18 then 'Good afternoon'
    else 'Good evening'
    end
  end

  # First C-Trax store whose card processing is not verified and enabled, shown
  # to users who may run the POS setup. Nil when everything is ready.
  def card_processing_down_location
    return unless Current.user&.can?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')
    return if request.path.start_with?('/pos_settings')
    ready = PosSetting.where(card_enabled: true).where.not(verified_at: nil).pluck(:location_id)
    Location.where(source: 'ctrax').where.not(id: ready).order(:name).first
  end
end
