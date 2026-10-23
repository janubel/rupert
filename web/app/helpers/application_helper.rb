# frozen_string_literal: true

module ApplicationHelper
  # Ask Rupert, the help chat, is for signed-in staff with the Rupert Chat permission
  # (administrators by default) in their own workspace (not customer-support views,
  # not the employee app) while an administrator keeps it on.
  def ask_rupert_available?
    return @ask_rupert_available if defined?(@ask_rupert_available)

    user = Current.user
    @ask_rupert_available = !!(user&.active? && !user.employee? && user.can?('chat.use') && Current.tenant_id == user.tenant_id && AskRupert::Config.current.enabled?)
  end

  # The Team chat unread badge polls the chat; same people who may open it.
  def team_chat_badge_available?
    Current.user.present? && TeamChat.allowed?(Current.user)
  end

  # --- Module-area navigation helpers (see ModuleRegistry) ---

  # The pages this person may open, computed once per request (the rail, the
  # start page and the active-page match all read it).
  def nav_entries
    @nav_entries ||= ModuleRegistry.nav_for(Current.user)
  end

  def nav_areas
    @nav_areas ||= ModuleRegistry.areas_for(Current.user, visible: nav_entries)
  end

  # Whether the header already offers this area. Account-menu shortcuts that an
  # area tab would repeat (My time clock, Features & roadmap) show only without it.
  def nav_area?(key)
    nav_areas.any? { |area| area[:key] == key.to_s }
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

    request_path = request.path
    return request_path == '/' ? 100 : 0 if path == '/'

    return path.length if request_path == path
    return path.length if request_path.start_with?("#{path}/")

    0
  end

  def active_module_entry
    @active_module_entry ||= nav_entries
      .select { |entry| module_match_strength(safe_module_path(entry)).positive? }
      .max_by { |entry| module_match_strength(safe_module_path(entry)) }
  end

  # The full-screen POS is never a landing page: the brand link and a section's rail link
  # skip it while the person has another page to go to, so they stay in the shell.
  FULL_SCREEN_MODULES = %w[ctrax_pos].freeze

  def navigation_start_path
    entry = nav_entries.find { |candidate| FULL_SCREEN_MODULES.exclude?(candidate.key) } || nav_entries.first
    entry ? safe_module_path(entry) : root_path
  end

  # The page a section's rail link opens: its first module that keeps the management shell.
  def area_landing_entry(area)
    area[:modules].find { |entry| FULL_SCREEN_MODULES.exclude?(entry.key) } || area[:modules].first
  end

  def active_area_key
    @active_area_key ||= ModuleRegistry.area_key_for(active_module_entry&.key) ||
                         nav_areas.first&.dig(:key)
  end

  def active_area_modules
    nav_areas.find { |area| area[:key] == active_area_key }&.dig(:modules) || []
  end

  # Sub-sections of the active area for the tools menu. Areas without groups get
  # one unnamed group so the menu renders a plain list as before.
  def active_area_groups
    groups = nav_areas.find { |area| area[:key] == active_area_key }&.dig(:groups)
    groups.presence || [{ name: nil, modules: active_area_modules }]
  end

  # Chart palette derived from the Tailwind @theme tokens in
  # app/assets/tailwind/application.css. Keep the two in sync.
  # Mid-lightness values that read on both the light and the dark surface.
  CHART_COLORS = {
    ink: '#3f4754',
    olive_deep: '#3b6fe0',
    clay: '#7b67c9',
    butter: '#e8b63f',
    rose: '#d2574a',
    sage: '#2f9a8d',
    fern: '#2f9a63'
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
  # Problems with the system itself, shown as a red badge on the bell and at the top of Notifications instead of a
  # banner on every page: [{ title:, body:, path:, link: }].
  def system_alerts
    @system_alerts ||= begin
      alerts = []
      if (location = card_processing_down_location)
        alerts << { title: 'Card processing is down', body: "Customers at #{location.name} cannot pay by card until the payment gateway is connected and verified.",
                    path: pos_setting_path(location.id), link: 'Open POS settings' }
      end
      alerts
    end
  end

  def card_processing_down_location
    return unless Current.user&.can?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')
    return if request.path.start_with?('/pos_settings')
    ready = PosSetting.where(card_enabled: true).where.not(verified_at: nil).pluck(:location_id)
    Location.where(source: 'ctrax').where.not(id: ready).order(:name).first
  end

  # Newer code exists on GitHub main than this build runs. Only for people who
  # manage settings, and hidden once they dismiss it for this build.
  def pending_update
    return unless Current.user&.can?('settings.write')
    return if session[:dismissed_update_for] == BuildInfo.current.revision

    UpdateChecker.pending
  end

  # What the server's updater will do with the pending update, when it has one.
  def update_install_hint
    return @update_install_hint if defined?(@update_install_hint)

    @update_install_hint = install_hint_for(AutoUpdate.status)
  end

  def install_hint_for(status)
    return if status.nil? || AutoUpdate.stale?(status)
    return 'Installing now.' if status.busy?
    return 'The last install failed and was rolled back.' if status.failed?
    return 'It installs when an operator clicks Install.' if AutoUpdate.manual?

    'It installs automatically once its checks pass.'
  end

  # Long explanatory copy shows its first sentence and keeps the rest one tap
  # away, so work screens stay scannable without hiding any caveat.
  def fold_explainer(text, **options)
    lead, rest = text.to_s.strip.split(/(?<=[.!?])\s+/, 2)
    classes = options[:class]
    return tag.p(text, class: classes) if rest.blank? || text.length < 140

    tag.div(class: classes) do
      safe_join([
        tag.p(lead),
        tag.details(class: 'explainer') do
          safe_join([tag.summary('More detail', class: 'explainer-summary'), tag.p(rest, class: 'mt-1')])
        end
      ])
    end
  end
end
