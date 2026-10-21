# frozen_string_literal: true

module Mcp
  module Tools
    class DeployStatus < Tool
      include OperationsAccess

      tool 'deploy_status',
        title: 'Auto-deploy status',
        description: 'What the host auto-deployer last reported (status.json and last-deploy.json under /var/lib/rupert-autodeploy): ' \
                     'state (idle, deploying, deployed, failed), the message, the running and target commits, whether installs are ' \
                     'manual, and the build this process is running. Not installed on every server. Server-wide, so it needs a ' \
                     'platform administrator. Read-only; needs the system:read scope.',
        scope: 'system:read'

      def call(_args)
        require_instance_operator!
        status = AutoUpdate.status
        data = { installed: status.present?, running_build: BuildInfo.current.revision, manual_mode: AutoUpdate.manual?,
                 status: report(status), last_deploy: report(AutoUpdate.last_deploy), generated_at: iso(Time.current) }
        text = status ? "Auto-deployer: #{status.state} — #{excerpt(status.message, 200)}" : 'No auto-deployer status file is present on this server.'
        result(text, data)
      end

      private

      def report(value)
        return unless value

        { state: value.state.to_s.first(40), message: excerpt(value.message, 300), current: value.current.to_s.first(64).presence, target: value.target.to_s.first(64).presence,
          mode: value.mode.to_s.first(20).presence, at: iso(value.at), stale: AutoUpdate.stale?(value) }
      end
    end
  end
end
