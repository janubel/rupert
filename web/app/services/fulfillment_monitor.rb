# frozen_string_literal: true

require 'digest'

# Reports online paid orders that have remained unfulfilled past the configured
# threshold. A signature prevents repeating an unchanged exception list.
class FulfillmentMonitor
  SIGNATURE_KEY = 'fulfillment_monitor_signature'
  DEFAULT_OVERDUE_HOURS = 24
  MAX_ORDERS = 25

  class << self
    def check!(channel: nil)
      new(channel: channel).check!
    end
  end

  def initialize(channel: nil)
    @room = channel.presence || announcements_channel
  end

  def check!
    orders = overdue_orders
    signature = signature_for(orders)
    return 0 if signature == previous_signature

    if orders.any?
      published, error = TeamChat::Notices.notify(format_message(orders), room: @room)
      raise "Fulfillment alert failed: #{error}" unless published
    end

    update_signature(signature)
    orders.length
  end

  private

  def overdue_orders
    Core::Order
      .where(channel: 'online', status: 'paid')
      .where.not(fulfillment_status: %w[shipped arrived completed])
      .where('occurred_at < ?', overdue_hours.hours.ago)
      .where.missing(:fulfillments)
      .order(:occurred_at, :id)
      .limit(MAX_ORDERS)
  end

  def overdue_hours
    value = EnvStore.fetch('FULFILLMENT_ALERT_HOURS', DEFAULT_OVERDUE_HOURS).to_i
    value.positive? ? value : DEFAULT_OVERDUE_HOURS
  end

  def announcements_channel
    TeamChat::Notices::ROOM_SLUG
  end

  def signature_for(orders)
    Digest::SHA256.hexdigest(orders.map(&:id).join("\n"))
  end

  def previous_signature
    Setting.find_by(key: SIGNATURE_KEY, tenant_id: Current.tenant_id)&.value
  end

  def update_signature(signature)
    setting = Setting.find_or_initialize_by(key: SIGNATURE_KEY, tenant_id: Current.tenant_id)
    setting.value = signature
    setting.save!
  end

  def format_message(orders)
    lines = orders.map do |order|
      age = ((Time.current - order.occurred_at) / 1.hour).floor
      amount = format('$%.2f', order.gross_cents.to_f / 100.0)
      "  • #{order.display_number} — #{amount} — #{age}h old"
    end
    "#{orders.length} online order(s) overdue for fulfillment:\n#{lines.join("\n")}"
  end
end
