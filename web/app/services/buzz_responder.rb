# frozen_string_literal: true

# Turns a channel message directed at Rupert into a reply. Pure logic — the
# listener decides when a message is for Rupert, this decides what to say.
class BuzzResponder
  def self.respond(message, mentions_me: true)
    new.respond(message)
  end

  def respond(message)
    text = message.to_s.strip
    return nil if text.blank?

    case text.downcase
    when /\b(help|commands|what can you do)\b/
      help_text
    when /\b(sync now|run a sync|start a sync)\b/
      start_sync!
    when /\b(counts?|pending count|inventory count)\b/
      counts_summary
    when /\b(low stock|alerts?|stockouts?)\b/
      alerts_summary
    when /\b(status|inventory status|how are you|health|what.?s new)\b/
      status_summary
    else
      acknowledgement
    end
  end

  private

  def help_text
    "I'm Rupert, your inventory & ops agent. I can: " \
      "run a sync ('sync now'), report status ('status'), " \
      "list pending manual counts ('counts'), and surface low stock ('low stock'). " \
      'Notifications about syncs and counts land in this channel automatically.'
  end

  def start_sync!
    SyncJob.perform_later(tenant_id: Current.tenant_id, mode: 'manual', actor: 'rupert-agent')
    "Sync started — I'll post here when it completes."
  end

  def status_summary
    last = SyncRun.order(startedAt: :desc).first
    sync_line = if last
      "Last sync: #{last.status} #{time_ago(last.startedAt)} (#{last.source || 'all'})"
    else
      'No syncs recorded yet.'
                end
    pending = InventoryCount.by_status('pending').count
    alerts = StockAlert.open.count
    low = StockAlert.open.where('quantity <= 0').count
    "#{sync_line} · #{pending} pending manual #{'count'.pluralize(pending)} · " \
      "#{alerts} open #{'alert'.pluralize(alerts)} (#{low} at zero)"
  end

  def counts_summary
    counts = InventoryCount.by_status('pending').recent(5)
    return 'No pending manual counts.' if counts.empty?

    lines = counts.map { |c| "• #{c.items.count} items / #{c.total_quantity} qty · counted #{time_ago(c.countedAt)}" }
    "Pending manual counts:\n#{lines.join("\n")}"
  end

  def alerts_summary
    alerts = StockAlert.open.order(createdAt: :desc).limit(5)
    return 'No open stock alerts — all good.' if alerts.empty?

    lines = alerts.map { |a| "• #{a.sku.presence || a.id.first(8)}: #{a.quantity} left / threshold #{a.threshold}" }
    "Open stock alerts:\n#{lines.join("\n")}"
  end

  def acknowledgement
    "Got it — noted. For what I can do, just say 'help'."
  end

  def time_ago(time)
    time ? ActionController::Base.helpers.time_ago_in_words(time) + ' ago' : '—'
  end
end
