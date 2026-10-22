# frozen_string_literal: true

# Who hears about what on a task. Assignment, comments and blocking reach the
# people responsible (assignee, project owner and members) but never the person
# who just did the thing. Every call is best effort.
module TaskNotifier
  module_function

  def assigned(task)
    return if task.assignee_id.blank?

    Notification.deliver(task.assignee_id, kind: 'task_assigned', title: "#{actor_name} assigned you: #{task.title}",
      body: [task.project&.name, task.due_label].compact.join(' · '), url: path(task))
  end

  def commented(task, comment)
    team(task).each do |user_id|
      Notification.deliver(user_id, kind: 'task_comment', title: "#{actor_name} commented on: #{task.title}",
        body: comment.body, url: path(task))
    end
  end

  def blocked(task)
    team(task).each do |user_id|
      Notification.deliver(user_id, kind: 'task_blocked', title: "Blocked: #{task.title}",
        body: task.blocked_reason.presence || "#{actor_name} marked it blocked.", url: path(task))
    end
  end

  def team(task)
    ids = [task.assignee_id, *task.project&.team_ids].compact_blank.map(&:to_s).uniq
    ids - [Current.user&.id.to_s]
  end

  def path(task)
    Rails.application.routes.url_helpers.projects_task_path(task)
  end

  def actor_name
    Current.user&.display_name || 'Someone'
  end
end
