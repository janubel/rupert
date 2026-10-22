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
    def propose!(reply, tool:, arguments:, proposed_for:, execution_info: {})
      authorize_room!(reply, proposed_for)
      raise Denied, 'This tool cannot be approved in chat.' unless LOCAL_TOOLS.include?(tool)

      arguments, assignee = pin_assignee(tool, arguments, proposed_for)
      mcp = Mcp::Registry.find(tool)
      action = {
        'id' => SecureRandom.uuid, 'tool' => tool, 'arguments' => arguments, 'status' => 'proposed',
        'title' => mcp&.title.to_s.sub(/\s*\(.*\)\z/, ''), 'summary' => summary(tool, arguments), 'proposed_for' => proposed_for.id
      }
      Approval.transaction(requires_new: true) do
        reply.with_lock do
          record = Approval.create!(message: reply, source_message_id: reply.id, public_id: action['id'],
            proposal: action, provenance: provenance(reply, proposed_for).merge(execution_info).merge(assignee))
          record.record!('proposed', user: proposed_for)
          reply.update!(actions: reply.actions_list + [action])
        end
      end
      action
    end

    # The existing tools mutate only this database. The mutation, immutable
    # receipt, audit events and notice commit together or all roll back.
    # Remote side effects must not be added to this allow-list without their
    # own upstream idempotency protocol and reconciliation mechanism.
    LOCAL_TOOLS = %w[create_task update_task submit_feedback].freeze

    def decide!(message, action_id, user:, approve:)
      action = nil
      message.with_lock do
        authorize_room!(message, user)
        record = find_or_adopt!(message, action_id)
        tool = Mcp::Registry.find(record.proposal['tool'])
        if approve
          raise Denied, 'You do not have permission to make this change.' unless LOCAL_TOOLS.include?(record.proposal['tool']) && permitted?(user, tool)
        end
        decision = approve ? 'approve' : 'dismiss'
        if record.state != 'proposed'
          raise Denied, 'This action was already decided.' unless record.decision == decision

          return record.action
        end
        raise Denied, 'This message is no longer available.' if message.deleted?
        verify_assignee!(record, user) if approve

        action = record.proposal.deep_dup
        action.merge!('decided_by' => user.display_name, 'decided_at' => Time.current.iso8601)
        record.record!(approve ? 'approved' : 'dismissed', user: user)
        if approve
          execute!(tool, action, user, record)
        else
          action['status'] = 'dismissed'
        end
        record.update!(state: action['status'], decision: decision, decided_by_id: user.id,
          decided_by_name: user.display_name, decided_at: Time.current, receipt: action)
        project!(message, record)
        announce(message, action)
      end
      action
    end

    def pin_assignee(tool, arguments, user)
      args = arguments.deep_stringify_keys
      return [args, {}] unless %w[create_task update_task].include?(tool) && (args['assignee'].present? || args['assign_to_me'])

      person = Mcp::Assignee.resolve(user, args['assignee'].presence || 'me')
      args['assignee'] = person == :nobody ? 'nobody' : person.email
      args.delete('assign_to_me')
      [args, { 'assignee_pinned' => true, 'assignee_id' => person == :nobody ? nil : person.id }]
    end

    def verify_assignee!(record, user)
      return unless record.provenance['assignee_pinned']

      person = Mcp::Assignee.resolve(user, record.proposal.dig('arguments', 'assignee'))
      id = person == :nobody ? nil : person.id
      raise Denied, 'The requested assignee changed. Ask for a new proposal.' unless id == record.provenance['assignee_id']
    rescue Mcp::ToolError
      raise Denied, 'The requested assignee is no longer available. Ask for a new proposal.'
    end

    def authorize_room!(message, user)
      unless user && user.tenant_id == message.tenant_id && Current.tenant_id == message.tenant_id && Token.new(user).usable? && TeamChat.allowed?(user) && message.room.visible_to?(user)
        raise Denied, 'You do not have access to this action.'
      end
    end

    # Adopt legacy JSON cards under the message lock. Their old terminal state
    # is a receipt, never permission to execute again. Attribution not recorded
    # by the old code is explicitly unknown rather than inferred from a new turn.
    def find_or_adopt!(message, id)
      record = Approval.find_by(source_message_id: message.id, public_id: id.to_s)
      return record if record

      action = message.actions_list.find { |candidate| candidate['id'] == id.to_s }
      raise ActiveRecord::RecordNotFound, 'No such action' unless action

      terminal = action['status'] != 'proposed'
      record = Approval.create!(message: message, source_message_id: message.id, public_id: action['id'], proposal: action,
        provenance: provenance(message, User.find_by(id: action['proposed_for']), legacy: true), state: action['status'],
        decision: (action['status'] == 'dismissed' ? 'dismiss' : 'approve' if terminal), receipt: terminal ? action : {})
      record.record!('legacy_imported', details: { status: action['status'] })
      record
    end

    def project!(message, record)
      cards = message.actions_list
      projected = cards.map { |card| card['id'] == record.public_id ? record.action : card }
      projected << record.action unless cards.any? { |card| card['id'] == record.public_id }
      message.update!(actions: projected)
    end

    # Called while the reply is locked by run cancellation/deadline expiry.
    def dismiss_pending!(message, reason:, user: nil)
      message.actions_list.each { |card| find_or_adopt!(message, card['id']) }
      Approval.where(source_message_id: message.id, state: 'proposed').find_each do |record|
        action = record.proposal.merge('status' => 'dismissed', 'result' => reason)
        action.merge!('decided_by' => user.display_name, 'decided_at' => Time.current.iso8601) if user
        record.update!(state: 'dismissed', decision: 'cancel', decided_at: Time.current, decided_by_id: user&.id, decided_by_name: user&.display_name, receipt: action)
        record.record!('cancelled', user: user, details: { reason: reason })
        project!(message, record)
      end
    end

    def execute!(tool, action, user, record)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = nil
      # A ToolError may follow a partial write. Roll back that write before
      # recording a failed receipt; retrying a failed receipt never reruns it.
      Approval.transaction(requires_new: true) do
        outcome = tool.new(token: Token.new(user, write: tool.scope)).call(action['arguments'] || {})
        action['status'] = 'done'
        action['result'] = outcome.text.to_s.first(300)
        action['assignee_id'] = outcome.data.to_h[:assignee_id].presence if outcome.data.to_h.key?(:assignee_id)
        record.record!('executed', user: user, details: { result: outcome.data.to_h, duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round })
        log_execution!(record, user, outcome)
      end
    rescue Mcp::ToolError => e
      action['status'] = 'failed'
      action['result'] = e.message.to_s.first(300)
      record.record!('failed', user: user, details: { error: action['result'], duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round })
    end

    def log_execution!(record, user, outcome)
      data = outcome.data.to_h
      task = Projects::Task.find_by(id: data[:id]) if %w[create_task update_task].include?(record.proposal['tool'])
      if task && record.proposal['tool'] == 'create_task'
        source = record.provenance
        task.update!(description: [task.description.presence, "Requested by #{source['requester_name'] || 'unknown'} via team chat. #{source['chat_url']}"].compact.join("\n\n"))
      end
      subject = task || (AgentFeedback.find_by(id: data[:id]) if record.proposal['tool'] == 'submit_feedback')
      ActivityLog.create!(tenant_id: record.tenant_id, user_id: user.id, actor_name: user.display_name, action: 'team_chat_action',
        subject_type: subject&.class&.name, subject_id: subject&.id&.to_s,
        details: JSON.generate(approval_id: record.id, tool: record.proposal['tool'], outcome: 'done', source: record.provenance))
    end

    def provenance(reply, requester, legacy: false)
      trigger = Message.find_by(id: reply.meta.to_h['trigger_id'], room_id: reply.room_id)
      requester = trigger.user if trigger&.person?
      configuration = reply.run&.configuration.to_h
      snapshot = reply.run&.request_context.to_h
      trigger_id = snapshot['trigger_id'] || trigger&.id
      parent_id = snapshot.key?('parent_id') ? snapshot['parent_id'] : trigger&.parent_id
      {
        'requester_id' => requester&.id, 'requester_name' => requester&.display_name,
        'trigger_id' => trigger&.id, 'last_chat' => trigger&.body, 'requested_at' => trigger&.created_at&.iso8601(6),
        'room_id' => reply.room_id, 'reply_id' => reply.id,
        'chat_url' => "/chat/#{reply.room.slug}#{"?#{"thread=#{parent_id}&" if parent_id}message=#{trigger_id}" if trigger_id}",
        'model' => configuration['model'] || reply.meta.to_h['model'],
        'engine' => configuration['engine'] || reply.meta.to_h['engine'],
        'harness' => legacy ? nil : 'TeamChat::Agent',
        'harness_version' => legacy ? nil : "RubyLLM #{RubyLLM::VERSION}",
        'build' => legacy ? nil : BuildInfo.current.revision,
        'proposed_at' => legacy ? nil : Time.current.iso8601(6), 'legacy' => legacy,
        'request_snapshot' => snapshot.present? ? 'captured_at_run_creation' : 'current_message'
      }.merge(snapshot.except('parent_id'))
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
