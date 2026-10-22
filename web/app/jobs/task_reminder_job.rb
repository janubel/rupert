# frozen_string_literal: true

# Morning nudge for the people who own tasks: what is due today, and what is
# overdue (once a week per task). Each reminder carries a dedupe key, so a
# re-run or a second worker never sends the same one twice.
class TaskReminderJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) { Time.use_zone('America/New_York') { remind } }
    rescue StandardError => e
      logger.error("#{self.class}: reminders failed for tenant #{tenant.id}: #{e.class}")
    end
  end

  private

  def remind
    today = Date.current
    week = today.strftime('%G-W%V')
    Projects::Task.unfinished.where.not(assignee_id: [nil, '']).where('due_on <= ?', today).find_each do |task|
      url = Rails.application.routes.url_helpers.projects_task_path(task)
      if task.due_on == today
        Notification.deliver(task.assignee_id, kind: 'task_due', title: "Due today: #{task.title}", body: task.project&.name,
          url: url, dedupe_key: "due:#{today.iso8601}:#{task.id}", actor: nil)
      else
        Notification.deliver(task.assignee_id, kind: 'task_overdue', title: "Overdue #{(today - task.due_on).to_i}d: #{task.title}",
          body: task.project&.name, url: url, dedupe_key: "overdue:#{week}:#{task.id}", actor: nil)
      end
    end
  end
end
