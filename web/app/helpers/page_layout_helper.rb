# frozen_string_literal: true

# One page header for every screen (docs/ui-standards.md §4). Width is chosen
# with a tier class on the page wrapper instead of ad-hoc max-w-* utilities:
#   .page-narrow  42rem  single-task forms and short detail pages
#   .page-medium  56rem  reading and settings pages
#   (default)     the layout's max-w-6xl, for tables and dashboards
module PageLayoutHelper
  # Renders the <h1>, subtitle, the primary action(s) and an optional "More"
  # menu, and sets the browser-tab title from the same text unless the view
  # already set one. Location is shown once, by the rail; pass eyebrow: only
  # when a page needs to name the kind of record it shows ("Customer").
  #
  #   <%= page_header 'Edit goal', subtitle: 'Targets for the month.' %>
  #   <%= page_header 'Customers', menu: [['Download CSV', export_customers_path], ['Sync now', sync_customers_path, { method: :post }]] do %>
  #     <%= link_to 'Add customer', new_customer_path, class: 'btn-primary' %>
  #   <% end %>
  def page_header(title, subtitle: nil, eyebrow: nil, menu: nil, &block)
    content_for(:title, title) unless content_for?(:title)
    actions = capture(&block) if block
    menu_html = page_menu(menu)

    tag.header(class: 'page-header') do
      safe_join([
        tag.div(class: 'page-header-main') do
          safe_join([
            (tag.p(eyebrow, class: 'eyebrow text-olive') if eyebrow.present?),
            tag.h1(title, class: 'page-title'),
            (tag.p(subtitle, class: 'page-subtitle') if subtitle.present?)
          ].compact)
        end,
        (tag.div(safe_join([menu_html, actions].compact), class: 'page-header-actions') if actions.present? || menu_html)
      ].compact)
    end
  end

  # "Section · Group" for the current page, from the registry; nil outside the app shell.
  def page_eyebrow
    return unless Current.user && respond_to?(:nav_areas) && respond_to?(:active_module_entry)

    area = nav_areas.find { |candidate| candidate[:key] == active_area_key }
    return unless area

    entry = active_module_entry
    group = entry && area[:groups]&.find { |candidate| candidate[:modules].any? { |mod| mod.key == entry.key } }
    [area[:name], group&.dig(:name)].compact.join(' · ')
  rescue StandardError
    nil
  end

  # The "More" overflow menu: a native disclosure so it works without JavaScript.
  # Items are [label, path] or [label, path, { method: :post, data: {...} }].
  def page_menu(items, label: 'More')
    items = Array(items).compact
    return if items.empty?

    tag.details(class: 'menu', data: { controller: 'navigation-menu' }) do
      safe_join([
        tag.summary(class: 'btn-ghost menu-trigger', aria: { haspopup: 'menu' }) { safe_join([label, navigation_icon('chevron', css_class: 'nav-symbol menu-chevron')]) },
        tag.div(class: 'menu-panel', role: 'menu') do
          safe_join(items.map do |text, path, options|
            options = (options || {}).dup
            if options.delete(:method).to_s.in?(%w[post patch put delete])
              button_to(text, path, options.merge(method: options[:method] || :post, class: 'menu-item', role: 'menuitem', form_class: 'contents'))
            else
              link_to(text, path, options.merge(class: 'menu-item', role: 'menuitem'))
            end
          end)
        end
      ])
    end
  end

  # Section heading inside a page: <h2> plus optional actions on the right. Pass id: when a
  # section is aria-labelledby this heading.
  #
  #   <%= section_heading 'Follow-ups due' do %><%= link_to 'Open all', ..., class: 'btn-ghost btn-sm' %><% end %>
  def section_heading(title, hint: nil, level: :h2, id: nil, &block)
    actions = capture(&block) if block
    tag.div(class: 'card-head') do
      safe_join([
        tag.div do
          safe_join([
            content_tag(level, title, class: level == :h2 ? 'section-title' : 'card-title', id: id),
            (tag.p(hint, class: 'card-hint') if hint.present?)
          ].compact)
        end,
        (tag.div(actions, class: 'card-head-actions') if actions.present?)
      ].compact)
    end
  end

  # Nothing here yet: what is missing and the one thing to do about it.
  #
  #   <%= empty_state 'No customers yet', hint: 'Add your first customer to start tracking follow-ups.' do %>
  #     <%= link_to 'Add customer', new_customer_path, class: 'btn-primary' %>
  #   <% end %>
  def empty_state(title, hint: nil, &block)
    action = capture(&block) if block
    tag.div(class: 'empty-state') do
      safe_join([
        tag.p(title, class: 'empty-state-title'),
        (tag.p(hint, class: 'empty-state-hint') if hint.present?),
        (tag.div(action, class: 'mt-3') if action.present?)
      ].compact)
    end
  end

  # In-page tabs for views of the same record or report (never for moving between modules).
  # tabs: [[label, path, active?], ...]
  def page_tabs(tabs, label:)
    tag.nav(class: 'tabs', aria: { label: label }) do
      safe_join(tabs.map do |text, path, active|
        link_to(text, path, class: "tab #{active ? 'tab-active' : ''}".strip, aria: { current: (active ? 'page' : nil) })
      end)
    end
  end
end
