# frozen_string_literal: true

class SourceSyncStatus
  FRESH_FOR = 60.minutes
  ACTIVE_BADGES = ['Live', 'Healthy', 'Syncing', 'Files current', 'Backing up', 'Recent API read'].freeze

  def self.all(include_platform: true)
    new.all(include_platform: include_platform)
  end

  def all(include_platform: true)
    keys = %i[shopify ctrax square swipesimple authorize_net bank]
    keys << :google_backup if include_platform
    keys.map { |key| read_status(key) }
  end

  private

  def read_status(key)
    send(key)
  rescue ActiveRecord::Encryption::Errors::Decryption
    label = { ctrax: 'C-Trax', swipesimple: 'SwipeSimple', authorize_net: 'Authorize.net',
      shopify: 'Shopify', square: 'Square', bank: 'Bank · NAB / IRIS', google_backup: 'Google Drive backup' }.fetch(key)
    { key: key.to_s, label: label, badge: 'Credentials unreadable', last_at: nil,
      detail: 'Ask the platform operator to restore the original encryption keys.',
      schedule: 'Saved schedule unchanged · access cannot be diagnosed', mode: 'unknown', ready: false }
  end

  def shopify
    platform('shopify', %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN])
  end

  def square
    platform('square', %w[SQUARE_ACCESS_TOKEN])
  end

  def platform(source, credential_keys)
    configured = credential_keys.all? { |key| EnvStore.fetch(key, '').present? }
    last_at = CatalogSyncHistory.watermark(source)
    # A combined run can fail or finish without ever reading Square.
    sources = source == 'shopify' ? %w[all shopify] : [source]
    run = SyncRun.where(source: sources).order(startedAt: :desc).first
    badge = if !configured
      'Needs access'
    elsif run&.status == 'running' && run.startedAt > SyncEngine::STALE_RUN_AFTER.ago
      'Syncing'
    elsif run&.failed? && (last_at.nil? || last_at.to_i < run.startedAt.to_i)
      'Error'
    elsif last_at.nil?
      'Awaiting pull'
    elsif last_at < FRESH_FOR.ago
      'Stale'
    else
      'Live'
    end
    latest_sale = Core::Order.where(source: source).maximum(:occurred_at)
    { key: source, label: source.capitalize, badge: badge, last_at: last_at,
      detail: source == 'shopify' ? "#{ShopifyProduct.active.where(catalog_present: true).count} current active products · #{ShopifyVariant.current_catalog.tracked.count} tracked variants" : 'Catalog and native order history',
      latest_sale_at: latest_sale, schedule: 'Every 15 minutes', mode: 'catalog', ready: configured }
  end

  def bank
    connection = PosConnection.find_by(provider: 'iris_reporting')
    latest = IrisReport.order(observed_at: :desc).first
    access = connection&.vendor_approved && connection.credentials_saved?
    web = connection&.reporting_auth_mode == 'web'
    last_at = access ? connection.last_reported_at : latest&.observed_at
    badge = if !access
      latest ? 'Portal imports' : 'Needs access'
    elsif connection.last_report_status == 'needs_login'
      'Needs login'
    elsif connection.last_report_status == 'running'
      'Syncing'
    elsif connection.last_report_status == 'failed'
      'Error'
    elsif !connection.reporting_enabled
      'Paused'
    elsif last_at.nil?
      'Awaiting pull'
    elsif last_at < 36.hours.ago
      'Stale'
    else
      'Live'
    end
    { key: 'bank', label: 'Bank · NAB / IRIS', badge: badge, last_at: last_at,
      detail: "#{IrisReport.count} processor deposit and summary snapshots",
      schedule: access && connection.reporting_enabled ? "Daily at 6:45 a.m. Eastern · #{web ? 'native website exports' : 'API reports'}" : 'Automatic pulls paused · CSV upload available',
      mode: 'bank', ready: access }
  end

  def google_backup
    connected = GoogleDriveBackupService.connected?
    logs = BackupLog.unscoped.where(tenant_id: nil)
    latest = logs.order(startedAt: :desc).first
    last_at = logs.where(status: 'success').order(finishedAt: :desc).first&.finishedAt
    badge = if !connected
      'Needs connection'
    elsif latest&.status == 'running'
      'Backing up'
    elsif latest&.status == 'failed'
      'Error'
    elsif last_at.nil?
      'Awaiting backup'
    elsif last_at < 8.hours.ago
      'Stale'
    else
      'Healthy'
    end
    { key: 'google_backup', label: 'Google Drive backup', badge: badge, last_at: last_at,
      detail: 'Automatic off-server database backup', schedule: 'Every 6 hours', mode: 'backup', ready: false }
  end

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
    latest_date = CtraxDay.maximum(:business_date)
    sales_at = latest_date && CtraxDay.where(business_date: latest_date).minimum(:captured_at)
    sales_badge = if sales_at.nil?
      'Awaiting pull'
    elsif latest_date < Date.current
      'Missing today'
    elsif sales_at < FRESH_FOR.ago
      'Stale'
    else
      'Live'
    end
    { key: 'ctrax', label: 'C-Trax', badge: badge, last_at: last_at,
      sales_last_at: sales_at, sales_badge: sales_badge, sales_date: latest_date,
      detail: "#{snapshots.size} stores · #{snapshots.sum { |snapshot| snapshot.records.size }} variants",
      schedule: connection&.hourly_sync_enabled ? 'Every 30 minutes' : 'Automatic stock pulls paused',
      mode: 'stock', ready: connection&.vendor_approved && connection.credentials_saved? }
  end

  def swipesimple
    exports = SwipesimpleExport.select(:id, :kind, :exported_at).to_a
    latest = exports.group_by(&:kind).transform_values { |rows| rows.max_by { |row| [row.exported_at, row.id] } }
    last_at = latest.values.map(&:exported_at).min
    connection = PosConnection.find_by(provider: 'swipesimple')
    access = connection&.vendor_approved && connection.credentials_saved?
    badge = if !access || connection.last_report_status == 'needs_login'
      'Needs login'
    elsif connection.last_report_status == 'running'
      'Syncing'
    elsif connection.last_report_status == 'failed'
      'Error'
    elsif !connection.reporting_enabled
      'Paused'
    elsif connection.last_reported_at.nil?
      'Awaiting pull'
    elsif connection.last_reported_at < FRESH_FOR.ago
      'Stale'
    else
      'Live'
    end
    rows = SwipesimpleReportRow.latest.group('swipesimple_exports.kind').count
    { key: 'swipesimple', label: 'SwipeSimple', badge: badge, last_at: connection&.last_reported_at || last_at,
      detail: "#{rows.fetch('transactions', 0)} transactions · #{rows.fetch('invoices', 0)} invoices",
      schedule: connection&.reporting_enabled ? 'Website pulls every 30 minutes' : 'Automatic website pulls paused',
      mode: 'web', ready: access }
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
    elsif last_at < 10.minutes.ago
      'Stale'
    else
      'Recent API read'
    end
    count = api ? AuthorizeNetTransaction.count : AuthorizeNetPortalExport.latest_records.size
    { key: 'authorize_net', label: 'Authorize.net', badge: badge, last_at: last_at,
      detail: "#{count} payment observations",
      schedule: api && connection.reporting_enabled ? 'Every 5 minutes · signed events when configured' : 'Manual snapshots · API credentials needed for live reporting',
      mode: api ? 'api' : 'portal', ready: true }
  end
end
