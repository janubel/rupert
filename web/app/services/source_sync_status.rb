# frozen_string_literal: true

class SourceSyncStatus
  FRESH_FOR = 60.minutes

  def self.all
    new.all
  end

  def all
    [ctrax, swipesimple, authorize_net]
  end

  private

  def ctrax
    connection = PosConnection.find_by(provider: 'ctrax')
    snapshots = CtraxStockSnapshot.all.to_a
    last_at = snapshots.map(&:captured_at).min
    badge = if !connection&.credentials_saved?
      'Needs access'
    elsif connection.last_check_status == 'failed'
      'Error'
    elsif !connection.hourly_sync_enabled
      'Paused'
    elsif last_at.nil?
      'Awaiting pull'
    elsif last_at < FRESH_FOR.ago
      'Stale'
    else
      'Live'
    end
    { key: 'ctrax', label: 'C-Trax', badge: badge, last_at: last_at,
      detail: "#{snapshots.size} stores · #{snapshots.sum { |snapshot| snapshot.records.size }} variants",
      schedule: connection&.hourly_sync_enabled ? 'Every 30 minutes' : 'Automatic stock pulls paused',
      mode: 'stock', ready: connection&.vendor_approved && connection.credentials_saved? }
  end

  def swipesimple
    exports = SwipesimpleExport.select(:id, :kind, :exported_at).to_a
    latest = exports.group_by(&:kind).transform_values { |rows| rows.max_by { |row| [row.exported_at, row.id] } }
    last_at = latest.values.map(&:exported_at).min
    delivery = ENV['RUPERT_SWIPESIMPLE_INBOX'].present?
    badge = if !delivery
      'Needs feed'
    elsif latest.size < 2
      'Awaiting files'
    elsif last_at < FRESH_FOR.ago
      'Stale export'
    else
      'Files current'
    end
    rows = SwipesimpleReportRow.latest.group('swipesimple_exports.kind').count
    { key: 'swipesimple', label: 'SwipeSimple', badge: badge, last_at: last_at,
      detail: "#{rows.fetch('transactions', 0)} transactions · #{rows.fetch('invoices', 0)} invoices",
      schedule: delivery ? 'Delivery checks every 30 minutes' : '30-minute checks await vendor delivery',
      mode: 'csv', ready: true }
  end

  def authorize_net
    connection = PosConnection.find_by(provider: 'authorize_net_reporting')
    portal = AuthorizeNetPortalExport.order(exported_at: :desc).first
    api = connection&.vendor_approved && connection.credentials_saved?
    last_at = api ? connection.last_reported_at : portal&.exported_at
    badge = if !api
      portal ? (portal.exported_at < FRESH_FOR.ago ? 'Stale snapshot' : 'Portal snapshot') : 'Portal sign-in'
    elsif connection.last_report_status == 'failed' || connection.last_check_status == 'failed'
      'Error'
    elsif !connection.reporting_enabled
      'Paused'
    elsif last_at.nil?
      'Awaiting pull'
    elsif last_at < FRESH_FOR.ago
      'Stale'
    else
      'Live'
    end
    count = api ? AuthorizeNetTransaction.count : AuthorizeNetPortalExport.latest_records.size
    { key: 'authorize_net', label: 'Authorize.net', badge: badge, last_at: last_at,
      detail: "#{count} payment observations",
      schedule: api && connection.reporting_enabled ? 'Every 30 minutes' : 'Portal exports on demand · API access deferred',
      mode: api ? 'api' : 'portal', ready: true }
  end
end
