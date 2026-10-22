# frozen_string_literal: true

module Mcp
  module Tools
    # Changes one task on Rupert's own task list (never Shopify, Square or
    # C-Trax): who it is for, its column, priority, due date, title, or a note.
    # Requires the tasks:write scope and the owner's permission to edit that task.
    class UpdateTask < Tool
      tool 'update_task',
        title: 'Update a task (writes to Rupert)',
        description: 'WRITES DATA: changes one task on Rupert\'s own Tasks board: assign it (a name, an email, "me" or "nobody"), ' \
                     'move it (todo, in_progress, blocked, done), change its priority or due date, rename it, or add a note. ' \
                     'It never changes Shopify, Square or C-Trax. Find the task ID with list_tasks first. Returns the task.',
        scope: 'tasks:write', read_only: false

      input_schema(
        type: 'object',
        properties: {
          task_id: { type: 'integer', minimum: 1, description: 'The task ID (from list_tasks rows).' },
          assignee: Assignee::PROPERTY,
          status: { type: 'string', enum: Projects::Task::BOARD_STATUSES, description: 'Board column to move it to.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES },
          due_on: DATE_PROPERTY.merge(description: 'New due date, YYYY-MM-DD.'),
          clear_due_date: { type: 'boolean', description: 'Remove the due date.' },
          title: { type: 'string', minLength: 1, maxLength: 200, description: 'New title.' },
          note: { type: 'string', maxLength: 1000, description: 'A note added to the end of the description.' }
        },
        required: %w[task_id],
        additionalProperties: false
      )

      def call(args)
        task = Projects::TaskPolicy::Scope.new(user, Projects::Task).resolve.find_by(id: args['task_id'])
        raise ToolError.new("No task ##{args['task_id']} that you can see.", kind: 'not_found') unless task
        raise ToolError.new("You cannot change task ##{task.id}.", kind: 'denied') unless Projects::TaskPolicy.new(user, task).update?

        changes = apply(task, args)
        target = args['status']
        raise ToolError.new('Say what to change: assignee, status, priority, due date, title or a note.', kind: 'invalid_arguments') if changes.empty? && target.blank?

        Projects::Task.transaction do
          raise ToolError.new("The task was not saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') if changes.any? && !task.save

          if target.present? && target != task.status
            raise ToolError.new("Task ##{task.id} cannot move from #{task.status} to #{target}.", kind: 'invalid_arguments') unless task.move_to!(target)

            changes << "moved to #{target.tr('_', ' ')}"
          end
        end
        raise ToolError.new("Task ##{task.id} already looks like that.", kind: 'invalid_arguments') if changes.empty?

        ActivityLogger.log('task_updated', subject: task, details: "Via MCP token #{token.token_hint}; #{changes.join('; ')}".first(500))
        result("Updated task ##{task.id} “#{task.title}”: #{changes.join(', ')}.",
          { id: task.id, title: task.title, status: task.status, priority: task.priority, due_on: task.due_on&.iso8601,
            assignee: task.assignee&.display_name, assignee_id: task.assignee_id })
      end

      private

      def apply(task, args)
        changes = []
        if args['assignee'].present?
          person = Assignee.resolve(user, args['assignee'])
          id = person == :nobody ? nil : person.id.to_s
          if id != task.assignee_id.presence
            task.assignee_id = id
            changes << (id ? "assigned to #{Assignee.label(person)}" : 'unassigned')
          end
        end
        if args['priority'].present? && args['priority'] != task.priority
          task.priority = args['priority']
          changes << "priority #{args['priority']}"
        end
        if args['clear_due_date'] && task.due_on
          task.due_on = nil
          changes << 'no due date'
        elsif args['due_on'].present? && (due = date_arg(args, 'due_on', nil)) != task.due_on
          task.due_on = due
          changes << "due #{due.iso8601}"
        end
        if args['title'].present? && (title = AgentFeedback.clean(args['title'], 200)) != task.title
          task.title = title
          changes << "renamed “#{title}”"
        end
        if args['note'].present?
          note = AgentFeedback.clean(args['note'], 1000, multiline: true)
          task.description = [task.description.presence, "#{note}\n— #{user.display_name}, via an AI assistant (#{Date.current.iso8601})"].compact.join("\n\n")
          changes << 'note added'
        end
        changes
      end
    end
  end
end
