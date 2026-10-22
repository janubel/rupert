# frozen_string_literal: true

# Static (non-AI) sales announcer. After a sync imports new orders, this
# service diffs the LedgerEntry rows newer than the last-announced watermark
# and posts a terse "item — amount" message to the Announcements channel.
#
# On first run with no watermark, it simply establishes a baseline at the
# newest existing order so historical sales are never re-announced in bulk.
class SalesAnnouncer
  WATERMARK_KEY = 'sales_announcer_watermark'
  REVENUE_STATUSES = %w[PAID COMPLETED].freeze
  BATCH_SIZE = 100

  class << self
    def announce!(channel: nil)
      new(channel: channel).announce!
    end
  end

  def initialize(channel: nil)
    @room = channel.presence || announcements_channel
  end

  # Returns the number of new sales announced (0 if none, or if team chat/watermark
  # isn't yet usable).
  def announce!
    return 0 unless TeamChat::Notices.configured?
    return 0 if baseline_not_established?

    entries = new_entries
    return 0 if entries.empty?

    published, error = TeamChat::Notices.notify(format_message(entries), room: @room)
    raise "Sales announcement failed: #{error}" unless published

    advance_watermark(entries)
    entries.length
  end

  private

  def announcements_channel
    TeamChat::Notices::ROOM_SLUG
  end

  def baseline_not_established?
    return false if watermark.present?

    # First run: set the watermark to the newest existing order (baseline) so
    # we only announce sales that arrive after this point.
    newest = LedgerEntry.order(occurredAt: :desc, id: :desc).first
    if newest
      update_watermark(newest)
    else
      # No orders at all yet — anchor to now so future orders count as new.
      update_watermark(Time.current)
    end
    true
  end

  def new_entries
    scope = LedgerEntry
            .where(status: REVENUE_STATUSES)
    scope = if watermark_id.present?
      scope.where(
        '"occurredAt" > :time OR ("occurredAt" = :time AND "LedgerEntry"."id" > :id)',
        time: watermark_time,
        id: watermark_id
      )
    else
      # Backward compatibility for the timestamp-only watermark already used
      # by the live branch.
      scope.where('"occurredAt" > ?', watermark_time)
            end
    scope.order(:occurredAt, :id).limit(BATCH_SIZE)
  end

  def format_message(entries)
    total = entries.length
    total_cents = entries.sum(&:grossCents)
    lines = entries.map do |entry|
      amount = format('$%.2f', entry.grossCents.to_f / 100.0)
      items = entry.summary.presence || 'Sale'
      "  • #{items} — #{amount}"
    end
    total_amt = format('$%.2f', total_cents.to_f / 100.0)
    "#{total} independent sale(s), #{total_amt} total:\n#{lines.join("\n")}"
  end

  def watermark
    @watermark ||= begin
      value = Setting.find_by(key: WATERMARK_KEY, tenant_id: Current.tenant_id)&.value
      if value.present?
        parsed = JSON.parse(value)
        { time: Time.zone.parse(parsed.fetch('occurred_at')), id: parsed['id'] }
      end
    rescue JSON::ParserError
      { time: Time.zone.parse(value), id: nil }
    end
  end

  def watermark_time
    watermark&.fetch(:time)
  end

  def watermark_id
    watermark&.fetch(:id)
  end

  def update_watermark(entry_or_time)
    time = entry_or_time.respond_to?(:occurredAt) ? entry_or_time.occurredAt : entry_or_time
    id = entry_or_time.respond_to?(:id) ? entry_or_time.id : nil
    setting = Setting.find_or_initialize_by(key: WATERMARK_KEY, tenant_id: Current.tenant_id)
    setting.value = { occurred_at: time.utc.iso8601(6), id: id }.to_json
    setting.save!
    @watermark = { time: time, id: id }
  end

  def advance_watermark(entries)
    newest = entries.max_by { |entry| [entry.occurredAt, entry.id] }
    update_watermark(newest) if newest
  end
end
