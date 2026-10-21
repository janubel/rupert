# frozen_string_literal: true

# One page header for every screen. Width is chosen with a tier class on the
# page wrapper instead of ad-hoc max-w-* utilities:
#   .page-narrow  42rem  single-task forms and short detail pages
#   .page-medium  56rem  reading and settings pages
#   (default)     the layout's max-w-6xl, for tables and dashboards
module PageLayoutHelper
  # Renders the eyebrow, <h1>, subtitle and an optional actions block, and sets
  # the browser-tab title from the same text unless the view already set one.
  #
  #   <%= page_header 'Edit goal', subtitle: 'Targets for the month.' %>
  #   <%= page_header 'Customers' do %><%= link_to 'Add customer', new_customer_path, class: 'btn-primary' %><% end %>
  def page_header(title, subtitle: nil, eyebrow: nil, &block)
    content_for(:title, title) unless content_for?(:title)
    actions = capture(&block) if block

    tag.header(class: 'page-header') do
      safe_join([
        tag.div(class: 'page-header-main') do
          safe_join([
            (tag.p(eyebrow, class: 'eyebrow text-olive') if eyebrow.present?),
            tag.h1(title, class: 'page-title'),
            (tag.p(subtitle, class: 'page-subtitle') if subtitle.present?)
          ].compact)
        end,
        (tag.div(actions, class: 'page-header-actions') if actions.present?)
      ].compact)
    end
  end
end
