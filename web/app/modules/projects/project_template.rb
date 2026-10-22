# frozen_string_literal: true

module Projects
  # A saved project outline: its tasks, checklists and their date offsets from
  # the project start. Stored as one JSON document so templates never appear as
  # real projects or tasks on any board.
  class ProjectTemplate < ApplicationRecord
    include TenantScoped

    self.table_name = 'project_templates'

    validates :name, presence: true, length: { maximum: 120 }
    validates :payload, presence: true

    scope :alphabetical, -> { order(Arel.sql('LOWER(project_templates.name)')) }

    def tasks
      Array(JSON.parse(payload)['tasks'])
    rescue JSON::ParserError
      []
    end

    def task_count = tasks.size

    def self.capture(project, name:, by: Current.user)
      origin = project.start_on || project.created_at.to_date
      tasks = project.tasks.by_board_order.includes(:checklist_items).map do |task|
        {
          'title' => task.title, 'description' => task.description, 'priority' => task.priority, 'labels' => task.labels,
          'recurrence' => task.recurrence, 'estimate_minutes' => task.estimate_minutes,
          'start_offset' => task.start_on ? (task.start_on - origin).to_i : nil,
          'due_offset' => task.due_on ? (task.due_on - origin).to_i : nil,
          'checklist' => task.checklist_items.map(&:title)
        }
      end
      create(name: name, description: project.description, created_by_id: by&.id,
        payload: JSON.generate('due_offset' => project.due_on ? (project.due_on - origin).to_i : nil, 'tasks' => tasks))
    end

    # Fills a new project from the outline, dating tasks from its start (today when unset).
    def build_into(project)
      origin = project.start_on || Date.current
      project.description = description if project.description.blank?
      project.due_on ||= origin + JSON.parse(payload)['due_offset'].to_i if JSON.parse(payload)['due_offset']
      tasks.each do |entry|
        task = project.tasks.build(
          title: entry['title'], description: entry['description'], priority: entry['priority'].presence_in(Projects::Task::PRIORITIES) || 'medium',
          labels: Array(entry['labels']), recurrence: entry['recurrence'].presence_in(Projects::Task::RECURRENCES.keys),
          estimate_minutes: entry['estimate_minutes'],
          start_on: (origin + entry['start_offset'] if entry['start_offset']), due_on: (origin + entry['due_offset'] if entry['due_offset'])
        )
        Array(entry['checklist']).each_with_index { |title, i| task.checklist_items.build(title: title, position: i) }
      end
    end
  end
end
