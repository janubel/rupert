# frozen_string_literal: true

require 'securerandom'

module TeamChat
  # Changes @rupert proposed. The model's tool call is stored on its reply as an
  # action card; nothing runs until a person who is allowed to make that change
  # presses Approve. The change then runs as *that* person (their permissions,
  # their name in the activity log), and Rupert posts what happened.
  module Actions
    class Denied < StandardError; end

    STATUSES = %w[proposed done failed dismissed].freeze

    module_function

    def permitted?(user, tool)
      return false unless tool && TeamChat.allowed?(user)

      tool.scope.nil? ? Token.new(user).usable? : Token.new(user, write: tool.scope).allows?(tool.scope)
    end

    # Saves the proposal on the reply and returns it.
    def propose!(reply, tool:, arguments:, proposed_for:)
      mcp = Mcp::Registry.find(tool)
      action = {
        'id' => SecureRandom.hex(6), 'tool' => tool, 'arguments' => arguments, 'status' => 'proposed',
        'title' => mcp&.title.to_s.sub(/\s*\(.*\)\z/, ''), 'summary' => summary(tool, arguments), 'proposed_for' => proposed_for.id
      }
      reply.update_columns(actions: (reply.actions_list + [action]), updated_at: Time.current)
      action
    end

    # Approve (runs the change) or dismiss. Returns the updated action.
    def decide!(message, action_id, user:, approve:)
      action = nil
      message.with_lock do
        list = message.actions_list.map(&:dup)
        action = list.find { |candidate| candidate['id'] == action_id.to_s }
        raise ActiveRecord::RecordNotFound, 'No such action' unless action
        raise Denied, 'This action was already decided.' unless action['status'] == 'proposed'

        if approve
          tool = Mcp::Registry.find(action['tool'])
          raise Denied, 'You do not have permission to make this change.' unless permitted?(user, tool)

          run(tool, action, user)
        else
          action['status'] = 'dismissed'
        end
        action['decided_by'] = user.display_name
        action['decided_at'] = Time.current.iso8601
        message.update!(actions: list)
      end
      announce(message, action)
      action
    end

    def run(tool, action, user)
      outcome = tool.new(token: Token.new(user, write: tool.scope)).call(action['arguments'] || {})
      action['status'] = 'done'
      action['result'] = outcome.text.to_s.first(300)
      ActivityLogger.log('team_chat_action', actor: user, details: "tool=#{tool.tool_name}; outcome=done")
    rescue Mcp::ToolError => e
      action['status'] = 'failed'
      action['result'] = e.message.to_s.first(300)
      ActivityLogger.log('team_chat_action', actor: user, details: "tool=#{tool.tool_name}; outcome=failed")
    end

    def announce(message, action)
      text =
        case action['status']
        when 'done' then "#{action['decided_by']} approved: #{action['result']}"
        when 'failed' then "#{action['decided_by']} approved “#{action['summary']}”, but it did not work: #{action['result']}"
        else "#{action['decided_by']} dismissed “#{action['summary']}”."
        end
      message.room.messages.create!(author_kind: 'system', body: text, parent_id: message.parent_id)
    end

    def summary(tool, args)
      case tool
      when 'create_task'
        extras = [args['priority'], ("due #{args['due_on']}" if args['due_on'].present?), ('assigned to them' if args['assign_to_me'])].compact
        "Create task “#{args['title'].to_s.first(120)}”#{" (#{extras.join(', ')})" if extras.any?}"
      when 'submit_feedback'
        "File #{args['kind'].to_s.tr('_', ' ').presence || 'feedback'}: “#{args['summary'].to_s.first(120)}”"
      else
        "#{tool.tr('_', ' ')}: #{(args['title'] || args['summary']).to_s.first(120)}"
      end
    end
  end
end
