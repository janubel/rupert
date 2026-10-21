# frozen_string_literal: true

module Mcp
  module Tools
    class GetWorkspaceInfo < Tool
      tool 'get_workspace_info',
        title: 'Workspace and token info',
        description: 'Start here. Returns the Rupert workspace (store) this token belongs to, its time zone and today\'s ' \
                     'date, the token\'s scopes and expiry, which tools this token can use, and which scopes would ' \
                     'unlock the others. Read-only; works with every valid token.'

      def call(_args)
        available, locked = Registry.tools.partition { |tool| tool.available_to?(token) }
        data = {
          workspace: { name: tenant.name, subdomain: tenant.subdomain, time_zone: Time.zone.name, today: Date.current.iso8601 },
          acting_as: { name: user.display_name, role: user.role },
          token: { name: token.name, hint: token.token_hint, scopes: token.scopes, expires_at: iso(token.expires_at) },
          tools: available.map(&:tool_name),
          locked_tools: locked.map { |tool| { name: tool.tool_name, needs_scope: tool.scope, needs_permission: tool.permission } },
          notes: [
            'Sales sources (Shopify, Square, Rupert POS, C-Trax, SwipeSimple) are reported separately; the same card sale can ' \
            'appear in a store and in its processor, so do not add sources together unless a tool says the total is safe.',
            'A missing value is unknown, not zero. A day with no stored sales is not proof of a zero-sales day.',
            'No tool writes to Shopify, Square or C-Trax.',
            'If something is confusing, fails, or you finish a task, please call submit_feedback so the owner can improve Rupert.'
          ]
        }
        text = "Workspace #{tenant.name} (#{Time.zone.name}, today #{Date.current.iso8601}). " \
               "This token can use #{available.size} tool#{'s' unless available.size == 1}: #{available.map(&:tool_name).join(', ')}."
        text += " #{locked.size} more need other scopes." if locked.any?
        result(text, data)
      end
    end
  end
end
