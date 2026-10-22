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
      action['assignee_id'] = outcome.data.to_h[:assignee_id].presence if outcome.data.to_h.key?(:assignee_id)
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
      message.room.messages.create!(author_kind: 'system', body: text, parent_id: message.parent_id, mentions: notify_ids(message.room, action).presence)
    end

    # The person a task was just given to sees the notice as a mention, when they use team chat.
    def notify_ids(room, action)
      return [] unless action['status'] == 'done' && action['assignee_id'].present?

      person = User.find_by(id: action['assignee_id'], tenant_id: room.tenant_id, active: true)
      return [] unless person && TeamChat.allowed?(person) && room.visible_to?(person)

      [person.id]
    end

    # The name on the card for a pinned email ("nobody" stays as it is).
    def person_label(value)
      return 'nobody' if value.to_s == 'nobody'

      person = User.find_by(email: value.to_s, tenant_id: Current.tenant_id)
      person ? Mcp::Assignee.label(person) : value.to_s.first(60)
    end

    def summary(tool, args)
      case tool
      when 'create_task'
        who = args['assignee'].present? ? "for #{person_label(args['assignee'])}" : ('assigned to them' if args['assign_to_me'])
        extras = [args['priority'], ("due #{args['due_on']}" if args['due_on'].present?), who].compact
        "Create task “#{args['title'].to_s.first(120)}”#{" (#{extras.join(', ')})" if extras.any?}"
      when 'update_task'
        changes = [("assign to #{person_label(args['assignee'])}" if args['assignee'].present?), ("move to #{args['status'].to_s.tr('_', ' ')}" if args['status'].present?),
                   ("priority #{args['priority']}" if args['priority'].present?), ("due #{args['due_on']}" if args['due_on'].present?),
                   ('remove the due date' if args['clear_due_date']), ("rename to “#{args['title'].to_s.first(80)}”" if args['title'].present?),
                   ('add a note' if args['note'].present?)].compact
        "Task ##{args['task_id']} “#{args['task_title'].to_s.first(80)}”: #{changes.join(', ').presence || 'no change'}"
      when 'submit_feedback'
        "File #{args['kind'].to_s.tr('_', ' ').presence || 'feedback'}: “#{args['summary'].to_s.first(120)}”"
      else
        "#{tool.tr('_', ' ')}: #{(args['title'] || args['summary']).to_s.first(120)}"
      end
    end
  end
end
