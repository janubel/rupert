# frozen_string_literal: true

# Display helpers for the cash flow dashboard. Amounts are integer cents.
module CashFlowHelper
  # "$12.4K" for tiles and axes; exact figures stay in the tables and tooltips.
  def cash_flow_compact(cents, currency: 'USD')
    return '—' if cents.nil?

    dollars = cents.abs / 100.0
    text = if dollars >= 1_000_000 then "#{number_with_precision(dollars / 1_000_000, precision: 2, strip_insignificant_zeros: true)}M"
    elsif dollars >= 10_000 then "#{number_with_precision(dollars / 1000, precision: 1, strip_insignificant_zeros: true)}K"
    else number_with_precision(dollars, precision: 2, delimiter: ',')
           end
    "#{cents.negative? ? FinanceHelper::MINUS : ''}#{currency == 'USD' ? '$' : "#{currency} "}#{text}"
  end

  # Change against the window just before this one, coloured by whether up is
  # good for this measure. Zero or missing previous: plain "no comparison".
  def cash_flow_delta(current, previous, good:, label: 'previous period')
    return tag.span("No #{label} to compare", class: 'text-xs text-taupe') if previous.nil? || previous.zero?

    change = current - previous
    pct = (change.to_f / previous.abs * 100).round
    improving = good == :down ? change.negative? : change.positive?
    css = change.zero? ? 'text-taupe' : improving ? 'text-fern' : 'text-rose'
    arrow = change.zero? ? '·' : change.positive? ? '▲' : '▼'
    tag.span(class: "text-xs #{css}") do
      safe_join([tag.span(arrow, aria: { hidden: true }), tag.strong(" #{pct.positive? ? '+' : ''}#{pct}%"), tag.span(" vs #{label}", class: 'text-taupe font-normal')])
    end
  end

  # Twelve-ish point sparkline: muted line, current bucket marked in the accent.
  # Decorative (aria-hidden); the figures beside it and the table carry the values.
  def cash_flow_sparkline(series, width: 120, height: 32)
    values = Array(series).last(24)
    return ''.html_safe if values.size < 2

    min, max = values.minmax
    span = (max - min).zero? ? 1.0 : (max - min).to_f
    step = width.to_f / (values.size - 1)
    points = values.each_with_index.map { |v, i| [(i * step).round(1), (height - 3 - ((v - min) / span) * (height - 6)).round(1)] }
    path = points.map.with_index { |(x, y), i| "#{i.zero? ? 'M' : 'L'}#{x} #{y}" }.join(' ')
    last_x, last_y = points.last
    content_tag(:svg, viewBox: "0 0 #{width} #{height}", width: width, height: height, class: 'cash-flow-sparkline', aria: { hidden: true }, focusable: 'false') do
      safe_join([tag.path(d: path, fill: 'none', stroke: 'var(--chart-muted)', 'stroke-width': 1.5, 'stroke-linejoin': 'round', 'stroke-linecap': 'round'),
                 tag.circle(cx: last_x, cy: last_y, r: 3, fill: 'var(--color-olive)', stroke: 'var(--color-paper)', 'stroke-width': 2)])
    end
  end

  # Horizontal bar list: label, bar, exact amount. One hue; the longest bar is full width.
  def cash_flow_bar_list(rows, color: 'var(--chart-out)', empty: 'Nothing recorded in this range.')
    return tag.p(empty, class: 'text-sm text-taupe') if rows.blank?

    max = rows.map(&:last).max.to_f
    tag.ol(class: 'cash-flow-bars') do
      safe_join(rows.map do |label, cents|
        width = max.positive? ? [(cents / max * 100).round(1), 1.5].max : 0
        tag.li(class: 'cash-flow-bar-row') do
          safe_join([tag.span(label, class: 'cash-flow-bar-label'),
                     tag.span(class: 'cash-flow-bar-track') { tag.span('', class: 'cash-flow-bar-fill', style: "width:#{width}%;background:#{color}") },
                     tag.span(finance_money_text(cents), class: 'cash-flow-bar-value money')])
        end
      end)
    end
  end

  def cash_flow_event_icon(kind)
    { 'sale' => '◆', 'bank_in' => '▲', 'bank_out' => '▼', 'expense' => '●', 'vendor_payment' => '●' }.fetch(kind, '·')
  end

  def cash_flow_event_path(event)
    case event[:kind]
    when 'bank_in', 'bank_out' then bank_statement_path(event[:document_id]) if event[:document_id]
    when 'expense' then finance_expenses_path
    when 'vendor_payment' then finance_vendor_payments_path
    when 'sale' then sales_path
    end
  end
end
