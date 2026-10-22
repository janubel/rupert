# frozen_string_literal: true

module RetailWorkspaceHelper
  def retail_business_access?(permission)
    Current.user && !Current.user.employee? && Current.user.can?(permission)
  end

  def retail_source_time(value)
    value&.in_time_zone&.strftime('%b %-d, %Y · %-I:%M %p %Z') || 'Not recorded'
  end

  def retail_event_time(value, timezone: Time.zone.name)
    return 'Not recorded' if value.blank?

    Time.iso8601(value).in_time_zone(timezone).strftime('%b %-d · %-I:%M %p %Z')
  rescue ArgumentError, TypeError
    'Unknown time'
  end

  def retail_check_label(value)
    value.end_with?(' tender') ? "#{retail_tender_label(value.delete_suffix(' tender'))} tender" : value
  end

  def retail_tender_label(value)
    { 'cash' => 'Cash', 'credit' => 'Card', 'standaloneCardTerminal' => 'Card terminal',
      'gift_card' => 'Gift card', 'loyalty' => 'Loyalty' }.fetch(value, value.to_s.humanize)
  end
end
