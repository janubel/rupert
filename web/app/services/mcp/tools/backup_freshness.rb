# frozen_string_literal: true

module Mcp
  module Tools
    class BackupFreshness < Tool
      include OperationsAccess

      FRESH_WITHIN = 8.hours
      LOCAL_DIRECTORIES = %w[/var/backups/rupert /var/backups/rupert/frequent].freeze

      tool 'backup_freshness',
        title: 'Backup freshness',
        description: 'Are backups current? The latest verified Google Drive backup (status, age, whether it is within 8 hours) and, ' \
                     'when this process can read them, the newest local snapshot files (name, size, age), and the state of each backup layer ' \
                     '(rolling snapshot, local set, encrypted off-host copy, off-machine mirror, restore drill) as shown on System → Backups. Names and ages only — ' \
                     'never contents or links. Server-wide, so it needs a platform administrator. Read-only; needs the system:read scope.',
        scope: 'system:read'

      def call(_args)
        require_instance_operator!
        layers = BackupStatus.layers
        logs = BackupLog.unscoped.where(tenant_id: nil)
        latest = logs.order(startedAt: :desc).first
        success = logs.where(status: 'success').where.not(finishedAt: nil).order(finishedAt: :desc).first
        age = success && ((Time.current - success.finishedAt) / 1.hour).round(1)
        data = {
          drive: { latest_status: latest&.status, latest_started_at: iso(latest&.startedAt), last_success_at: iso(success&.finishedAt),
                   last_success_age_hours: age, fresh: !age.nil? && age <= FRESH_WITHIN / 1.hour, fresh_within_hours: FRESH_WITHIN / 1.hour },
          local: LOCAL_DIRECTORIES.map { |directory| local_snapshots(directory) },
          layers: layers.map do |layer|
            { key: layer.key, label: layer.label, every: layer.every, state: layer.state, protects: layer.protects,
              last_report_at: iso(layer.report&.at), message: layer.report&.message, kept: layer.report&.kept }
          end,
          layers_summary: BackupStatus.summary(layers),
          generated_at: iso(Time.current)
        }
        text = success ? "Last verified Drive backup #{age} hours ago (#{data[:drive][:fresh] ? 'fresh' : 'STALE'})." : 'No verified Drive backup is recorded.'
        text += " Backup layers: #{layers.map { |layer| "#{layer.key} #{layer.state}" }.join(', ')} (#{data[:layers_summary]})."

        result(text, data)
      end

      private

      def local_snapshots(directory)
        files = Dir.glob(File.join(directory, '*.{sqlite3,gz,tar,zip,enc}')).select { |path| File.file?(path) }.sort_by { |path| -File.mtime(path).to_i }
        newest = files.first
        { directory: directory, readable: File.directory?(directory) && File.readable?(directory), files: files.size,
          newest: newest && { name: File.basename(newest), bytes: File.size(newest), age_hours: ((Time.current - File.mtime(newest)) / 1.hour).round(1) } }
      rescue SystemCallError
        { directory: directory, readable: false, files: 0, newest: nil }
      end
    end
  end
end
