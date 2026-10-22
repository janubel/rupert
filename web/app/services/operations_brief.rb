# frozen_string_literal: true

# Builds deterministic management briefs from the canonical store database.
# No model calls are involved; every figure is reproducible from stored rows.
class OperationsBrief
  TIME_ZONE = 'America/New_York'
  REVENUE_STATUSES = %w[paid fulfilled].freeze

  class << self
    def publish!(kind, channel: nil)
      new(kind: kind, channel: channel).publish!
    end
  end

  def initialize(kind:, channel: nil)
    @kind = kind.to_s
    @room = channel.presence || announcements_channel
  end

  def publish!
    Time.use_zone(TIME_ZONE) do
      content, period_key = build
      return false if already_published?(period_key)

      published, error = TeamChat::Notices.notify(content, room: @room)
      raise "Operations brief failed: #{error}" unless published

      mark_published(period_key)
      true
    end
  end

  private

  def build
    case @kind
    when 'daily_close' then daily_close
    when 'morning' then morning
    when 'weekly' then weekly
    else raise ArgumentError, "Unknown operations brief: #{@kind}"
    end
  end

  def daily_close
    date = Time.zone.today
    orders = revenue_orders.where(occurred_at: date.all_day)
    previous = revenue_orders.where(occurred_at: (date - 1.day).all_day)
    lines = [
      "Daily store close — #{date.strftime('%b %-d')}",
      metric_line(orders, comparison: previous),
      "Channels: #{channel_breakdown(orders)}",
      "Top items: #{top_items(orders)}",
      "Exceptions: #{exception_summary}"
    ]
    [lines.join("\n"), date.iso8601]
  end

  def morning
    date = Time.zone.today
    last_sync = SyncRun.order(startedAt: :desc).first
    sync_text = if last_sync
      "#{last_sync.status} at #{last_sync.startedAt.in_time_zone.strftime('%-I:%M %p')}"
    else
      'no sync recorded'
                end
    content = [
      "Morning action brief — #{date.strftime('%b %-d')}",
      "Sync: #{sync_text}",
      "Yesterday: #{metric_line(revenue_orders.where(occurred_at: (date - 1.day).all_day))}",
      "Action queue: #{exception_summary}"
    ].join("\n")
    [content, date.iso8601]
  end

  def weekly
    end_date = Time.zone.today.beginning_of_day
    current = revenue_orders.where(occurred_at: (end_date - 7.days)...end_date)
    previous = revenue_orders.where(occurred_at: (end_date - 14.days)...(end_date - 7.days))
    content = [
      "Weekly business review — week ending #{(end_date - 1.day).strftime('%b %-d')}",
      metric_line(current, comparison: previous),
      "Channels: #{channel_breakdown(current)}",
      "Top items: #{top_items(current, limit: 5)}",
      "Operations: #{sync_failure_count(end_date)} sync failure(s) · #{exception_summary}"
    ].join("\n")
    [content, end_date.to_date.iso8601]
  end

  def revenue_orders
    Core::Order.where(status: REVENUE_STATUSES)
  end

  def metric_line(orders, comparison: nil)
    count = orders.count
    gross = orders.sum(:gross_cents)
    line = "#{count} order(s) · #{money(gross)} gross"
    return line unless comparison

    previous_gross = comparison.sum(:gross_cents)
    change = previous_gross.zero? ? nil : ((gross - previous_gross) * 100.0 / previous_gross).round(1)
    change ? "#{line} · #{format('%+.1f', change)}% vs prior period" : "#{line} · prior comparison unavailable"
  end

  def channel_breakdown(orders)
    counts = orders.group(:source).count
    totals = orders.group(:source).sum(:gross_cents)
    return 'none' if counts.empty?

    counts.sort.map { |source, count| "#{source}: #{count}/#{money(totals.fetch(source))}" }.join(' · ')
  end

  def top_items(orders, limit: 3)
    items = Core::OrderLine.where(order_id: orders.select(:id)).group(:name).sum(:quantity)
    top = items.sort_by { |name, quantity| [-quantity, name.to_s] }.first(limit)
    top.any? ? top.map { |name, quantity| "#{name.presence || 'Unnamed item'} (#{quantity})" }.join(', ') : 'none'
  end

  def exception_summary
    overdue = Core::Order.where(channel: 'online', status: 'paid')
                         .where.not(fulfillment_status: %w[shipped arrived completed])
                         .where('occurred_at < ?', 24.hours.ago)
                         .where.missing(:fulfillments)
                         .count
    open_alerts = StockAlert.open.count
    zero_stock = StockAlert.open.where('quantity <= 0').count
    "#{overdue} overdue fulfillment · #{open_alerts} stock alert(s) (#{zero_stock} at zero)"
  end

  def sync_failure_count(end_date)
    SyncRun.where(status: 'failed', startedAt: (end_date - 7.days)...end_date).count
  end

  def money(cents)
    format('$%.2f', cents.to_f / 100.0)
  end

  def announcements_channel
    TeamChat::Notices::ROOM_SLUG
  end

  def publication_key
    "operations_brief_#{@kind}_last_period"
  end

  def already_published?(period_key)
    Setting.find_by(key: publication_key, tenant_id: Current.tenant_id)&.value == period_key
  end

  def mark_published(period_key)
    setting = Setting.find_or_initialize_by(key: publication_key, tenant_id: Current.tenant_id)
    setting.value = period_key
    setting.save!
  end
end
