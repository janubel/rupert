# frozen_string_literal: true

module Mcp
  module Tools
    # Adds a task to Rupert's own task list — never Shopify, Square or C-Trax.
    # Requires the tasks:write scope.
    class CreateTask < Tool
      tool 'create_task',
        title: 'Create a task (writes to Rupert)',
        description: 'WRITES DATA: adds one task to Rupert\'s own Tasks board (status todo). It never changes Shopify, Square ' \
                     'or C-Trax. The description is marked as added by an AI assistant. Confirm with the person you are ' \
                     'helping before creating tasks. Returns the new task.',
        scope: 'tasks:write', read_only: false

      input_schema(
        type: 'object',
        properties: {
          title: { type: 'string', minLength: 1, maxLength: 200, description: 'Short task title.' },
          description: { type: 'string', maxLength: 4000, description: 'Details for the person doing the task.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES, description: 'Default medium.' },
          due_on: DATE_PROPERTY.merge(description: 'Optional due date, YYYY-MM-DD.'),
          project_id: { type: 'string', maxLength: 40, description: 'Optional project ID (from list_tasks rows).' },
          assignee: Assignee::PROPERTY,
          assign_to_me: { type: 'boolean', description: 'Assign to the token owner. Default unassigned.' }
        },
        required: %w[title],
        additionalProperties: false
      )

      def call(args)
        raise ToolError.new('This token\'s owner can no longer create tasks.', kind: 'denied') unless Projects::TaskPolicy.new(user, Projects::Task).create?

        project = Projects::Project.find_by(id: args['project_id']) if args['project_id'].present?
        raise ToolError.new("No project with ID #{args['project_id'].to_s.first(40)} exists in this workspace.", kind: 'not_found') if args['project_id'].present? && !project

        assignee = args['assignee'].present? ? Assignee.resolve(user, args['assignee']) : (user if args['assign_to_me'])
        assignee = nil if assignee == :nobody
        note = "Added by an AI assistant through Rupert MCP (token “#{token.name}”)."
        description = [AgentFeedback.clean(args['description'], 4000, multiline: true), note].compact.join("\n\n")
        task = (project ? project.tasks : Projects::Task).new(
          title: AgentFeedback.clean(args['title'], 200), description: description, priority: args['priority'] || 'medium',
          due_on: (date_arg(args, 'due_on', nil) if args['due_on'].present?), assignee_id: assignee&.id&.to_s
        )
        raise ToolError.new("The task was not saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') unless task.save

        ActivityLogger.log('task_created', subject: task, details: "Via MCP token #{token.token_hint}; assignee: #{task.assignee_id.presence || 'unassigned'}")
        result("Created task ##{task.id} “#{task.title}” (#{task.priority}#{", due #{task.due_on.iso8601}" if task.due_on})#{", assigned to #{Assignee.label(assignee)}" if assignee}.",
          { id: task.id, title: task.title, status: task.status, priority: task.priority, due_on: task.due_on&.iso8601, project_id: task.project_id&.to_s,
            assignee: assignee&.display_name, assignee_id: task.assignee_id })
      end
    end
  end
end
