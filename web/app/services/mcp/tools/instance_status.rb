# frozen_string_literal: true

module Mcp
  module Tools
    class InstanceStatus < Tool
      include OperationsAccess

      BOOTED_AT = Time.current

      tool 'instance_status',
        title: 'Rupert instance status',
        description: 'Is Rupert healthy right now? The running build, process uptime, the same four readiness checks as ' \
                     '/up/ready (database, queue worker, last sync, disk — one word each), and a few workspace counts. ' \
                     'Read-only; needs the system:read scope.',
        scope: 'system:read'

      def call(_args)
        build = BuildInfo.current
        checks = { database: ReadinessCheck.database_status, worker: ReadinessCheck.worker_status,
                   last_sync: ReadinessCheck.sync_status, disk: ReadinessCheck.disk_status }
        ready = checks.values.all? { |value| %w[ok unconfigured].include?(value) }
        data = {
          ready: ready, checks: checks,
          build: { revision: build.revision, short: build.short_revision, built_at: iso(build.built_at) },
          process: { started_at: iso(BOOTED_AT), uptime_seconds: (Time.current - BOOTED_AT).to_i, rails: Rails.version, ruby: RUBY_VERSION,
                     environment: Rails.env, node_mode: WorkspaceNode.isolated? ? 'workspace' : 'shared' },
          workspace: { name: tenant.name, active_users: User.where(tenant_id: tenant.id, active: true).count,
                       open_feedback_reports: AgentFeedback.where(status: %w[new triaged planned]).count,
                       new_feedback_reports: AgentFeedback.where(status: 'new').count },
          generated_at: iso(Time.current)
        }
        text = "#{ready ? 'Ready' : 'NOT ready'} — #{checks.map { |key, value| "#{key} #{value}" }.join(', ')}. Build #{build.short_revision}, " \
               "up #{ActiveSupport::Duration.build(data[:process][:uptime_seconds]).inspect}."
        result(text, data)
      end
    end
  end
end
