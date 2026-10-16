# frozen_string_literal: true

module CustomersHelper
  def customer_money(totals)
    return '—' if totals.empty?

    totals.sort_by { |currency, _| currency.to_s }.map do |currency, cents|
      "#{currency.presence || 'Unknown currency'} #{number_with_precision(cents / 100.0, precision: 2, delimiter: ',')}"
    end.join(' · ')
  end

  def customer_directory_status(customer)
    return 'Added manually' if customer.source == 'manual'

    latest = @directory_states&.dig(customer.source)&.last_success_at
    latest && customer.source_synced_at == latest ? 'Verified in latest read' : 'Unverified / historical'
  end

  def directory_label(source)
    { 'ctrax' => 'C-Trax', 'shopify' => 'Shopify', 'square' => 'Square', 'swipesimple' => 'SwipeSimple' }.fetch(source, source.to_s.titleize)
  end
end
