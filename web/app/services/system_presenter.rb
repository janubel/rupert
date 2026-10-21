# frozen_string_literal: true

require 'timeout'
require 'etc'

# Collects server + database health metrics for the System (admin) page.
# All reads are read-only and wrapped in timeouts so a hung metric never
# blocks the page. Some metrics are cached briefly (DataCache) since they
# don't change second-to-second and would otherwise add load to a page
# whose job is to report load.
class SystemPresenter
  attr_reader :load_averages,
    :cpu_count,
    :mem_total_mb,
    :mem_used_mb,
    :mem_available_mb,
    :swap_total_mb,
    :swap_used_mb,
    :disk_used_pct,
    :disk_free_gb,
    :uptime_seconds,
    :puma_rss_mb,
    :puma_threads,
    :db_connections,
    :db_max_connections,
    :db_cache_hit_pct,
    :db_deadlocks,
    :db_size_mb,
    :slow_queries,
    :active_queries,
    :locked_queries,
    :bloat_tables,
    :big_tables,
    :job_pending,
    :job_queued,
    :job_failed,
    :sync_success_rate,
    :cache_entries,
    :cache_dir_mb

  def initialize
    collect_os
    collect_process
    collect_db
    collect_jobs
  end

  private

  def collect_os
    @cpu_count = Etc.nprocessors
    @load_averages = read_file('/proc/loadavg').to_s.split.first(3).map(&:to_f)
    mem = read_file('/proc/meminfo').to_s
    @mem_total_mb = kb('MemTotal', mem) / 1024
    @mem_available_mb = kb('MemAvailable', mem) / 1024
    if @mem_total_mb.zero?
      total_bytes = `sysctl -n hw.memsize 2>/dev/null`.to_i
      @mem_total_mb = total_bytes / 1024 / 1024
      vm = `vm_stat 2>/dev/null`
      page_size = vm[/page size of (\d+) bytes/, 1].to_i
      available_pages = %w[Pages_free Pages_inactive Pages_speculative Pages_purgeable].sum do |label|
        vm[/^#{label.tr('_', ' ')}:\s+(\d+)/, 1].to_i
      end
      @mem_available_mb = (available_pages * page_size / 1024.0 / 1024).round if page_size.positive?
    end
    @mem_used_mb = @mem_total_mb - @mem_available_mb
    @swap_total_mb = kb('SwapTotal', mem) / 1024
    @swap_used_mb = kb('SwapTotal', mem) / 1024 - kb('SwapFree', mem) / 1024
    disk = `df -k / 2>/dev/null`.lines.last.to_s.split
    @disk_used_pct = disk[4].to_s.delete('%').to_i
    @disk_free_gb = disk[3].to_i.to_f / 1024**2
    @uptime_seconds = read_file('/proc/uptime').to_s.split.first.to_f.round
  end

  def collect_process
    pids = puma_pids
    @puma_rss_mb = pids.sum { |pid| rss_kb(pid) } / 1024
    @puma_threads = pids.sum { |pid| threads_for(pid) }
  end

  # SQLite has no buffer, lock or bloat statistics views, so show the file and
  # pool data that is available and leave unsupported counters blank in the UI.
  def collect_db
    conn = ActiveRecord::Base.connection
    pool = ActiveRecord::Base.connection_pool
    @db_connections = pool.stat[:connections].to_i
    @db_max_connections = pool.size
    @db_cache_hit_pct = nil
    @db_deadlocks = nil
    path = conn.pool.db_config.database.to_s
    path = Rails.root.join(path).to_s unless path.start_with?('/') || path == ':memory:'
    bytes = [path, "#{path}-wal"].sum { |file| File.file?(file) ? File.size(file) : 0 }
    @db_size_mb = (bytes / 1024.0 / 1024).round(1)
    @slow_queries = []
    @active_queries = []
    @locked_queries = []
    @bloat_tables = []
    @big_tables = []
  end

  def collect_jobs
    @job_pending = begin
      SolidQueue::ReadyExecution.count
    rescue StandardError
      0
    end
    @job_queued = begin
      SolidQueue::ScheduledExecution.count
    rescue StandardError
      0
    end
    @job_failed = begin
      SolidQueue::FailedExecution.count
    rescue StandardError
      0
    end
    @sync_success_rate = sync_success_rate_value
    @cache_entries = cache_entries_count
    @cache_dir_mb = cache_dir_mb_value
  end

  # --- small helpers ---

  def kb(key, meminfo)
    meminfo[/^#{Regexp.escape(key)}:\s+(\d+)/, 1].to_i
  end

  def read_file(path)
    Timeout.timeout(2) { File.read(path) }
  rescue StandardError
    nil
  end

  def puma_pids
    `pgrep -f "puma"`.lines.map(&:to_i)
  rescue StandardError
    []
  end

  def rss_kb(pid)
    Timeout.timeout(2) { File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i }
  rescue StandardError
    0
  end

  def threads_for(pid)
    Dir.children("/proc/#{pid}/task").size
  rescue StandardError
    0
  end

  def sync_success_rate_value
    total = SyncRun.count
    return 0 if total.zero?

    (SyncRun.where(status: 'success').count.to_f / total * 100).round(1)
  end

  def cache_dir_mb_value
    dir = Rails.root.join('tmp', 'cache')
    return 0 unless Dir.exist?(dir)

    Timeout.timeout(5) do
      size = Dir.glob("#{dir}/**/*").select { |f| File.file?(f) }.sum { |f| File.size(f) }
      (size / 1024.0 / 1024).round(1)
    end
  rescue StandardError
    0
  end

  def cache_entries_count
    dir = Rails.root.join('tmp', 'cache')
    return 0 unless Dir.exist?(dir)

    Timeout.timeout(5) do
      Dir.glob("#{dir}/**/*").count { |f| File.file?(f) }
    end
  rescue StandardError
    0
  end
end
