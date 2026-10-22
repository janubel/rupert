# frozen_string_literal: true

module TaskActivityHelper
  # Batch lookups for the history panel. Never render stored chat text or trust
  # a URL from an audit payload: rebuild links from messages the viewer can see.
  def task_ai_activities(entries)
    ai_entries = entries.select { |entry| entry.action == 'team_chat_action' }
    payloads = ai_entries.to_h { |entry| [entry.id, task_ai_payload(entry.details)] }
    approvals = TeamChat::Approval.where(id: payloads.values.filter_map { |data| task_activity_id(data['approval_id']) }, state: 'done').index_by(&:id)
    sources = payloads.transform_values { |data| data['source'].is_a?(Hash) ? data['source'] : {} }
    messages = {}
    rooms = {}
    if TeamChat.allowed?(Current.user)
      rooms = TeamChat::Room.visible_to(Current.user).where(id: sources.values.filter_map { |source| task_activity_id(source['room_id']) }).index_by(&:id)
      messages = TeamChat::Message.visible.where(room_id: rooms.keys, id: sources.values.filter_map { |source| task_activity_id(source['trigger_id']) }).index_by(&:id)
    end
    ai_entries.to_h do |entry|
      data = payloads.fetch(entry.id)
      source = sources.fetch(entry.id)
      approval = approvals[task_activity_id(data['approval_id'])]
      tool = data['tool']
      approval = nil unless approval && approval.source_message_id == task_activity_id(source['reply_id']) && approval.proposal['tool'] == tool
      label = if tool == 'create_task'
        'AI created task'
      elsif tool == 'update_task'
        approval&.proposal&.dig('arguments', 'status') == 'done' ? 'AI closed task' : 'AI updated task'
      else
        'AI action'
      end
      message = messages[task_activity_id(source['trigger_id'])]
      room = rooms[task_activity_id(source['room_id'])]
      path = if room && message && message.room_id == room.id
        team_chat_room_path(room.slug, message: message.id, thread: message.parent_id)
      end
      harness = [source['harness'], source['harness_version']].select { |part| part.is_a?(String) && part.present? }.join(' · ')
      [entry.id, { label: label, result: approval&.receipt&.fetch('result', nil), requester: task_ai_text(source['requester_name']),
                   model: task_ai_text(source['model']), harness: task_ai_text(harness), requested_at: task_ai_time(source['requested_at']),
                   source_path: path, source_label: source['trigger_id'].present? ? 'Private or unavailable chat' : 'Not recorded' }]
    end
  end

  def task_activity_id(value)
    number = value if value.is_a?(Integer)
    number = value.to_i if value.is_a?(String) && value.match?(/\A[1-9]\d{0,18}\z/)
    number if number && number.positive? && number <= 9_223_372_036_854_775_807
  end

  def task_ai_payload(details)
    parsed = JSON.parse(details.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def task_ai_text(value)
    value.is_a?(String) && value.present? ? value : 'Not recorded'
  end

  def task_ai_time(value)
    Time.iso8601(value).in_time_zone if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def task_activity_timestamp(time)
    time.in_time_zone.strftime('%b %-d, %Y at %-I:%M:%S %p %Z')
  end
end
