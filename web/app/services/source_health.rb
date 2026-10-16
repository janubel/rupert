# frozen_string_literal: true

# Read-only projection. Missing historical evidence stays unknown. No error
# messages, credentials, account IDs, queue arguments or hostnames enter HTML.
class SourceHealth
  CHANNELS = {
    'ctrax' => [['stock', 'Stock', 60.minutes], ['sales', 'Daily sales', 60.minutes]],
    'swipesimple' => [['web', 'Website exports', 60.minutes]],
    'authorize_net' => [['reporting', 'Reporting API', 10.minutes]],
    'shopify' => [['catalog', 'Catalog and orders', 60.minutes]],
    'square' => [['catalog', 'Catalog and orders', 60.minutes], ['timecards', 'Employee hours', 30.minutes]],
    'bank' => [['reporting', 'Processor reports', 36.hours]],
    'google_backup' => [['backup', 'Verified backup', 8.hours]]
  }.freeze

  def self.for(source)
    return [] if source[:key] == 'google_backup' && !ConnectionControlCenter.platform_admin?

    new(source).channels
  end

  def initialize(source)
    @source = source
    @connection = PosConnection.find_by(provider: ConnectionControlCenter::SOURCE_SETUP[source[:key]])
  end

  def channels
    entries = CHANNELS.fetch(@source[:key], [])
    entries = [['web', 'Native website deposits', 36.hours]] if @source[:key] == 'bank' && @connection&.reporting_auth_mode == 'web'
    entries.map { |operation, label, freshness| channel(operation, label, freshness) }
  end

  private

  def channel(operation, label, freshness)
    scope = @source[:key] == 'google_backup' ? SyncAttempt.unscoped.where(tenant_id: nil) : SyncAttempt.all
    scope = scope.where(source: @source[:key], operation: operation)
    # Queue/start order wins over completion order: a slow older failure must
    # not replace a newer successful acquisition.
    history = scope.order(Arel.sql('COALESCE(started_at, queued_at) DESC'), id: :desc).limit(5).to_a
    latest = history.find { |attempt| attempt.status != 'skipped' }
    success = scope.where(status: 'succeeded').order(Arel.sql('COALESCE(started_at, queued_at) DESC'), id: :desc).first
    success_at = success&.finished_at
    legacy_at = legacy_success(operation)
    queue = SyncQueueHealth.execution(latest)
    enabled = enabled?(operation)
    category = latest&.error_category
    category = 'worker' if %w[queued running].include?(latest&.status) && queue[:state] == 'Failed in worker'
    failure_current = category && latest && (!success || (order_key(latest) <=> order_key(success)).positive?)
    category = nil unless failure_current
    state = if failure_current
      'Failed'
    elsif latest&.status == 'running'
      latest.started_at < 45.minutes.ago ? 'Read stalled' : 'Reading'
    elsif latest&.status == 'queued'
      latest.queued_at < 15.minutes.ago && !queue[:retry_at] ? 'Queue delayed' : 'Queued'
    elsif !enabled
      'Automatic reads paused'
    elsif success_at.nil? && legacy_at && legacy_at < freshness.ago
      'Historical evidence stale'
    elsif success_at.nil?
      'Awaiting observed success'
    elsif success_at < freshness.ago
      'Stale'
    else
      'Current acquisition'
    end
    if state == 'Current acquisition' && @source[:key] == 'bank' && operation == 'reporting' && @connection&.last_report_status == 'partial'
      state = 'Partial acquisition'
      category = 'optional_reports'
    end
    if @source[:badge] == 'Credentials unreadable'
      state = 'Saved credentials unreadable'
      category = 'encryption'
    end
    # Legacy badges identify symptoms but cannot establish an exact failure
    # reason or attempt timestamp. Never classify saved free-text messages.
    if latest.nil? && %w[Error Needs\ login].include?(@source[:badge])
      state = 'Legacy failure · cause unknown'
      category = 'unknown'
    end
    title, action = guidance(state, category)
    {
      operation: operation, label: label, state: state, category: category,
      reason: title, action: action, enabled: enabled,
      alert: ['Failed', 'Read stalled', 'Queue delayed', 'Stale', 'Partial acquisition', 'Saved credentials unreadable', 'Historical evidence stale', 'Legacy failure · cause unknown'].include?(state),
      last_attempt_at: latest&.started_at, queued_at: latest&.queued_at,
      last_success_at: success_at, legacy_at: legacy_at, source_at: source_time(operation),
      source_event_at: nil, coverage: coverage(operation),
      worker: SyncQueueHealth.worker, queue: queue,
      reference: latest ? "SYNC-#{latest.id}" : nil,
      history: history.map { |attempt| receipt(attempt) },
      transition: transition(history)
    }
  rescue ActiveRecord::Encryption::Errors::Decryption
    title, action = SyncFailure::GUIDANCE.fetch('encryption')
    { operation: operation, label: label, state: 'Saved credentials unreadable', alert: true,
      reason: title, action: action, history: [],
      worker: { state: 'Unknown', last_at: nil }, queue: { state: 'Unknown', retry_at: nil } }
  rescue ActiveRecord::ActiveRecordError
    { operation: operation, label: label, state: 'Diagnostics unavailable', alert: true,
      reason: 'Local diagnostic history could not be read',
      action: 'Ask the operator to verify the migration and database. Keep credentials and schedules unchanged.',
      history: [], worker: { state: 'Unknown', last_at: nil }, queue: { state: 'Unknown', retry_at: nil } }
  end

  def order_key(attempt)
    [(attempt.started_at || attempt.queued_at).to_f, attempt.id]
  end

  def enabled?(operation)
    case @source[:key]
    when 'ctrax' then operation == 'stock' ? @connection&.hourly_sync_enabled : @connection&.reporting_enabled
    when 'swipesimple', 'authorize_net', 'bank' then @connection&.reporting_enabled
    when 'shopify' then @source[:ready]
    when 'square' then operation == 'timecards' ? SquareTimecardSync.enabled? : EnvStore.fetch('SQUARE_ACCESS_TOKEN', '').present?
    when 'google_backup' then GoogleDriveBackupService.connected?
    end
  end

  def legacy_success(operation)
    return SquareTimecard.maximum(:last_seen_at) if @source[:key] == 'square' && operation == 'timecards'

    case @source[:key]
    when 'ctrax'
      operation == 'stock' ? CtraxStockSnapshot.minimum(:captured_at) : CtraxDay.maximum(:captured_at)
    when 'swipesimple', 'authorize_net', 'bank' then @connection&.last_reported_at
    when 'shopify', 'square'
      SyncRun.where(source: @source[:key], status: 'success').maximum(:finishedAt)
    when 'google_backup' then BackupLog.unscoped.where(tenant_id: nil, status: 'success').maximum(:finishedAt)
    end
  end

  def source_time(operation)
    return SquareTimecard.maximum(:source_updated_at) if @source[:key] == 'square' && operation == 'timecards'

    return nil if @source[:key] == 'google_backup'
    return CtraxDay.maximum(:captured_at) if @source[:key] == 'ctrax' && operation == 'sales'

    @source[:last_at]
  end

  def coverage(operation)
    if @source[:key] == 'square' && operation == 'timecards'
      return 'Complete timecard search. Closed matched shifts count once; open, unmatched and overlapping work waits for review. Corrections retain original hours; history does not establish payroll payment.'
    end

    case @source[:key]
    when 'ctrax'
      if operation == 'stock'
        'Latest stored store stock snapshots; not a vendor event watermark.'
      else
        dates = [CtraxDay.minimum(:business_date), CtraxDay.maximum(:business_date)]
        dates.all? ? "Stored business dates #{dates.first}–#{dates.last}; intervening dates and reconciliation must be reviewed separately." : 'No daily sales snapshots recorded.'
      end
    when 'swipesimple' then 'Stored transaction and invoice exports; successful acquisition or replay does not prove new source activity or complete history.'
    when 'bank' then 'Stored merchant report windows can overlap; successful acquisition does not establish complete settlement or bank coverage.'
    when 'authorize_net' then 'Reporting-window observations; settlement and signed-event coverage require separate review.'
    when 'google_backup' then 'Verified backup acquisition; a restore drill remains a separate recovery check.'
    else 'Catalog and order acquisition; event-time completeness is not recorded as a coverage watermark.'
    end
  end

  def guidance(state, category)
    return SyncFailure::GUIDANCE.fetch(category) if category

    case state
    when 'Stale', 'Historical evidence stale' then ['No recent successful acquisition evidence', 'Check the worker heartbeat and queue, then try one read after checking access. Do not change credentials just because source data is stale.']
    when 'Read stalled', 'Queue delayed' then ['Job progress needs review', 'Ask the operator to inspect the worker and queue using the support reference. Do not queue repeated reads or change credentials.']
    when 'Automatic reads paused' then ['Existing schedule is paused', 'Review why it was paused and check read access. Enable its schedule only when intended; this diagnostic page never enables it.']
    when 'Current acquisition' then ['Recent successful acquisition', 'Review source timestamps and coverage separately. A successful replay does not prove new sales or complete history.']
    when 'Queued', 'Reading' then ['Read is in progress', 'Review queue progress before starting another read.']
    else ['No instrumented successful read yet', 'Check saved access, run one deliberate read, and review its result. Historical timestamps remain separate from new diagnostic receipts.']
    end
  end

  def receipt(attempt)
    { reference: "SYNC-#{attempt.id}", status: attempt.status, at: attempt.started_at || attempt.queued_at,
      reason: attempt.error_category && SyncFailure::GUIDANCE.fetch(attempt.error_category).first }
  end

  def transition(history)
    completed = history.select { |attempt| %w[succeeded failed].include?(attempt.status) }
    completed.each_cons(2) do |current, previous|
      next if current.status == previous.status && current.error_category == previous.error_category

      return { label: current.status == 'succeeded' ? 'Recovered' : 'Failure changed', at: current.finished_at }
    end
    nil
  end
end
