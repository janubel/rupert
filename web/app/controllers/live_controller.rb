# frozen_string_literal: true

# Turbo Stream endpoint that pages poll to hot-reload sync data while a sync
# runs. Each response replaces the sync banner, the "last synced" line, the
# recent runs list, and the header status pill. Targets that aren't on the
# current page are ignored by Turbo.
class LiveController < AuthenticatedController
  before_action :authorize_read

  # GET /live/sync_status — turbo_stream with live sync updates
  def sync_status
    @running = SyncEngine.running?
    @last_sync = SyncRun.order(startedAt: :desc).first
    @just_finished = @last_sync&.finishedAt.present? && @last_sync.finishedAt > 8.seconds.ago
    @runs = SyncRun.recent(25)

    render(turbo_stream: live_streams)
  end

  private

  def live_streams
    streams = [
      turbo_stream.replace('sync-banner', partial: 'syncs/banner'),
      turbo_stream.replace('last-sync', partial: 'shared/last_sync'),
      turbo_stream.replace('sync-runs', partial: 'syncs/runs'),
      turbo_stream.replace('header-sync-pill', partial: 'shared/header_sync_pill')
    ]
    streams << turbo_stream.replace('source-sync-status', partial: 'home/source_sync_status') if params[:source_status] == '1'
    streams
  end

  def authorize_read
    authorize(:module, :sync_read?)
  end
end
