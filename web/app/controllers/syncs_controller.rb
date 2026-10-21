# frozen_string_literal: true

require 'csv'

class SyncsController < AuthenticatedController
  SWIPESIMPLE_CONTRACT = 'rupert-swipesimple-line-items-v1'
  SWIPESIMPLE_PREVIEW_LIFETIME = 15.minutes

  before_action :authorize_read, only: :index
  before_action :authorize_write, only: %i[create source preview_swipesimple import_swipesimple]
  before_action :prevent_import_caching, only: %i[index preview_swipesimple import_swipesimple]
  before_action :authorize_push_approve, only: :push_guard_approve
  before_action :authorize_push_freeze, only: %i[push_guard_freeze push_guard_unfreeze]

  def index
    load_sync_history
  end

  def create
    SyncJob.perform_later(tenant_id: Current.tenant_id, mode: 'manual', actor: Current.user.email)
    redirect_to(syncs_path, notice: 'Full sync started')
  rescue SyncEngine::AlreadyRunning => e
    redirect_to(syncs_path, alert: e.message)
  end

  def source
    source = params[:source].to_s
    if %w[shopify square].include?(source)
      SyncJob.perform_later(tenant_id: Current.tenant_id, mode: 'manual', source: source, actor: Current.user.email)
      redirect_to(syncs_path, notice: "#{source.capitalize} sync started")
    else
      redirect_to(syncs_path, alert: 'Unknown source')
    end
  end

  def preview_swipesimple
    preview = SwipesimpleImporter.preview(swipesimple_csv)
    @swipesimple_preview = preview.summary
    @swipesimple_preview_token = import_verifier.generate(
      { 'tenant_id' => Current.tenant_id, 'user_id' => Current.user.id.to_s,
        'fingerprint' => preview.fingerprint, 'contract' => SWIPESIMPLE_CONTRACT },
      expires_in: SWIPESIMPLE_PREVIEW_LIFETIME, purpose: SWIPESIMPLE_CONTRACT
    )
    respond_to do |format|
      format.json { render json: { preview: @swipesimple_preview, preview_token: @swipesimple_preview_token } }
      format.html do
        load_sync_history
        render :index
      end
    end
  rescue ArgumentError, CSV::MalformedCSVError => e
    import_error(e)
  end

  # Only a reviewed, unchanged file can be imported. The signed token contains
  # a digest and access scope, never raw export contents or customer data.
  def import_swipesimple
    confirmation = import_verifier.verified(params[:preview_token].to_s, purpose: SWIPESIMPLE_CONTRACT)
    unless confirmation.is_a?(Hash) && confirmation['tenant_id'] == Current.tenant_id &&
      confirmation['user_id'] == Current.user.id.to_s && confirmation['contract'] == SWIPESIMPLE_CONTRACT
      raise ArgumentError, 'Preview this export before importing. Previews expire after 15 minutes.'
    end

    summary = SyncEngine.import_swipesimple_csv!(swipesimple_csv, actor: Current.user.email,
      expected_fingerprint: confirmation.fetch('fingerprint'))
    OpsLog.import(kind: 'swipesimple_orders', outcome: 'ok', rows: summary.orders, lines: summary.lines, unchanged: summary.unchanged_orders,
      skipped: summary.skipped_rows)
    notice = "Imported #{summary.orders} new order(s), #{summary.lines} line(s) from SwipeSimple."
    notice += " #{summary.unchanged_orders} unchanged order(s) left intact." if summary.unchanged_orders.positive?
    notice += " #{summary.skipped_rows} blank row(s) skipped." if summary.skipped_rows.positive?
    redirect_to(syncs_path, notice: notice)
  rescue ArgumentError, CSV::MalformedCSVError, SyncEngine::AlreadyRunning => e
    OpsLog.import(kind: 'swipesimple_orders', outcome: 'rejected', error_class: e.class.name)
    import_error(e)
  end

  # POST /syncs/push_guard_approve — the acting user records an explicit
  # approval toward opening a push window for a platform.
  def push_guard_approve
    platform = params[:platform].to_s
    result = PlatformPushGuard.approve!(platform, email: Current.user.email)
    if result[:window_open]
      expires = result[:window_expires_at]
      redirect_to(syncs_path,
        notice: "Push window for #{PlatformPushGuard.label(platform)} is OPEN (#{result[:approved_by]}/#{result[:needed]} approvals) until #{I18n.l(
          Time.zone.parse(expires), format: :short
        )}.")
    else
      redirect_to(syncs_path,
        notice: "Approval recorded for #{PlatformPushGuard.label(platform)} — #{result[:approved_by]} of #{result[:needed]} approvals still needed before writes unlock.")
    end
  rescue PlatformPushGuard::LockedError => e
    redirect_to(syncs_path, alert: e.message)
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  # POST /syncs/push_guard_freeze — hard block on all pushes to a platform
  # (maintenance/update mode), overriding any open approval window.
  def push_guard_freeze
    platform = params[:platform].to_s
    reason = params[:reason].to_s.presence || 'maintenance'
    PlatformPushGuard.freeze!(platform, reason: reason, actor: Current.user.email)
    redirect_to(syncs_path,
      notice: "#{PlatformPushGuard.label(platform)} pushes are now FROZEN — no writes or syncs will run against it until unfrozen.")
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  # POST /syncs/push_guard_unfreeze — lift a maintenance freeze (writes still
  # require an open approval window).
  def push_guard_unfreeze
    platform = params[:platform].to_s
    PlatformPushGuard.unfreeze!(platform, actor: Current.user.email)
    redirect_to(syncs_path,
      notice: "#{PlatformPushGuard.label(platform)} is unfrozen. Pushes still need an approved window to run.")
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  private

  def load_sync_history
    @runs = SyncRun.recent(25)
    @recent_movements = InventoryMovement.includes(:sync_run).order(createdAt: :desc).limit(12)
  end

  def prevent_import_caching
    response.headers['Cache-Control'] = 'no-store'
  end

  def import_verifier
    Rails.application.message_verifier('swipesimple-import-preview')
  end

  def swipesimple_csv
    if params[:file].present? && params[:text].present?
      raise ArgumentError, 'Choose a CSV file or paste text, rather than supplying both.'
    end

    text = if params[:file].is_a?(ActionDispatch::Http::UploadedFile)
      raise ArgumentError, 'The export is too large.' if params[:file].size > SwipesimpleImporter::MAX_BYTES

      params[:file].read(SwipesimpleImporter::MAX_BYTES + 1)
    elsif params[:text].is_a?(String)
      params[:text]
    end
    raise ArgumentError, 'Attach a CSV file or paste the export text.' if text.blank?
    raise ArgumentError, 'The export is too large.' if text.bytesize > SwipesimpleImporter::MAX_BYTES

    text
  end

  def import_error(error)
    message = error.is_a?(CSV::MalformedCSVError) ? 'The export is not valid CSV. Check its quoting and row structure.' : error.message
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_entity }
      format.html { redirect_to(syncs_path(anchor: 'swipesimple'), alert: message) }
    end
  end

  def authorize_read
    authorize(:module, :sync_read?)
  end

  def authorize_write
    authorize(:module, :sync_write?)
  end

  def authorize_push_approve
    authorize(:module, :reconcile_write?)
  end

  def authorize_push_freeze
    authorize(:module, :settings_write?)
  end
end
