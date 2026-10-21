# frozen_string_literal: true

# Turns a feedback row into a task in the "Rupert Feedback" project, assigned to
# the workspace owner (the oldest active administrator). The project is created
# on first use. Titles and descriptions come from untrusted text, so they are
# length-capped here and shown escaped wherever tasks are listed.
module FeedbackTask
  PROJECT_NAME = 'Rupert Feedback'
  PROJECT_DESCRIPTION = 'Bugs, requests and questions from the ladybug in Rupert, from teammates in chat and from connected ' \
                        'AI assistants. Each task links to its report; attachments are visible to administrators only.'
  PRIORITIES = { 'high' => 'high', 'normal' => 'medium', 'low' => 'low' }.freeze
  DESCRIPTION_MAX = 3500

  module_function

  # The person feedback tasks are assigned to. Nil only in a workspace with no active administrator.
  def owner
    people = User.where(tenant_id: Current.tenant_id, active: true)
    people.where(role: 'admin').order(:id).first || people.where(role: 'super_admin').order(:id).first
  end

  def project
    Projects::Project.find_by(name: PROJECT_NAME) || begin
      created = Projects::Project.create!(name: PROJECT_NAME, description: PROJECT_DESCRIPTION, owner_id: owner&.id&.to_s)
      created.start! if created.may_start?
      created
    end
  rescue ActiveRecord::RecordInvalid
    Projects::Project.find_by!(name: PROJECT_NAME)
  end

  # Creates the task and links it from the feedback. Returns the task.
  def create_for!(feedback, context_line: nil)
    task = project.tasks.create!(
      title: "#{feedback.kind_label}: #{feedback.summary}".first(200), priority: PRIORITIES.fetch(feedback.severity, 'medium'),
      assignee_id: owner&.id&.to_s, description: description(feedback, context_line)
    )
    feedback.update_columns(task_id: task.id, updated_at: Time.current)
    task
  end

  def description(feedback, context_line)
    footer = ["Report ##{feedback.id} (#{feedback.source}): /feedback_reports/#{feedback.id}", context_line].compact.join("\n")
    [feedback.details.to_s.first(DESCRIPTION_MAX).presence, footer].compact.join("\n\n")
  end
end
