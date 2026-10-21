# frozen_string_literal: true

module Mcp
  # Read-only reference documents an assistant can load: how to work with
  # Rupert's data, and the tools this particular token may use.
  module Resources
    GUIDE_URI = 'rupert://guide/getting-started'
    TOOLS_URI = 'rupert://guide/tools'

    GUIDE = <<~MARKDOWN
      # Working with Rupert

      Rupert is a retail ERP for one store (a "workspace"). It mirrors Shopify, Square, C-Trax and SwipeSimple data
      into its own database and adds bookkeeping, staff time, tasks and reports. Your token belongs to one workspace
      and one owner; you only ever see that workspace, and only what the token's scopes and the owner's current
      permissions allow.

      ## Rules of thumb
      - Call `get_workspace_info` first: it tells you the store, its time zone, today's date and your tools.
      - Dates are ISO `YYYY-MM-DD` in the workspace time zone. Ranges are inclusive.
      - Money is integer cents unless a field says otherwise.
      - Sources are separate. The same card sale can appear in a store (Shopify, Square, C-Trax) and in its
        processor (SwipeSimple). Never add sources together unless a tool says its total is safe.
      - `null` means unknown or not reported — never treat it as zero. A day with no stored sales is not proof of a
        zero-sales day (a sync may be missing).
      - Stock from different platforms or locations is an independent observation. Do not sum or "fix" it.
      - Tools are read-only except `create_task` (Rupert's own task board) and `submit_feedback`. No tool writes to
        Shopify, Square or C-Trax.
      - Lists are paginated: follow `meta.next_page` while `meta.has_more` is true. At most 50 rows per page.

      ## Help us improve
      The owner reads everything sent through `submit_feedback`. Please send one when:
      - a tool errors, returns something that looks wrong, or you could not find the data you needed (`struggle`,
        `bug`, `report_issue`);
      - you finish a task for your user (`task_report`: what you did, what was hard);
      - you have an idea for a better tool or report (`suggestion`).
      Failed and denied tool calls are also counted automatically, so the owner sees where assistants get stuck.
      Never include passwords, card numbers or other secrets in feedback.
    MARKDOWN

    def self.list
      [
        { uri: GUIDE_URI, name: 'getting-started', title: 'How to work with Rupert', mimeType: 'text/markdown',
          description: 'Data conventions (sources, unknown vs zero, cents, dates) and how to send feedback.' },
        { uri: TOOLS_URI, name: 'tools', title: 'Tools this token can use', mimeType: 'text/markdown',
          description: 'The tools available to this token, and the scopes that would unlock the others.' }
      ]
    end

    def self.read(uri, token)
      case uri
      when GUIDE_URI then GUIDE
      when TOOLS_URI then tools_markdown(token)
      end
    end

    def self.tools_markdown(token)
      available, locked = Registry.tools.partition { |tool| tool.available_to?(token) }
      lines = ['# Rupert MCP tools for this token', '', '## Available']
      lines += available.map { |tool| "- `#{tool.tool_name}`#{' (writes to Rupert)' unless tool.read_only} — #{tool.title}" }
      if locked.any?
        lines += ['', '## Not available to this token']
        lines += locked.map { |tool| "- `#{tool.tool_name}` — needs scope `#{tool.scope}` and owner permission `#{tool.permission}`" }
        lines << '' << 'Ask the workspace owner to issue a token with the needed scope (Rupert → API access).'
      end
      "#{lines.join("\n")}\n"
    end
  end
end
