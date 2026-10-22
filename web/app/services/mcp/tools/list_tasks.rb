# frozen_string_literal: true

module Mcp
  module Tools
    class ListTasks < Tool
      tool 'list_tasks',
        title: 'List tasks',
        description: 'Lists Rupert project tasks (the in-app Tasks board), most urgent first: title, status ' \
                     '(todo, in_progress, blocked, done), priority, due date, project and assignee. Filter by status, ' \
                     'priority, text, overdue, or tasks assigned to the token owner. Paginated. Read-only.',
        scope: 'tasks:read'

      input_schema(
        type: 'object',
        properties: {
          status: { type: 'string', enum: Projects::Task::BOARD_STATUSES + ['open'], description: 'open = todo or in_progress. Default: every status except done.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES },
          query: { type: 'string', maxLength: 100, description: 'Text in the title or description.' },
          overdue: { type: 'boolean', description: 'Only tasks past their due date and not done.' },
          assigned_to_me: { type: 'boolean', description: 'Only tasks assigned to the token owner.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        tasks = Projects::TaskPolicy::Scope.new(user, Projects::Task).resolve.includes(:project, :assignee)
        tasks = case args['status']
        when nil then tasks.where.not(status: 'done')
        when 'open' then tasks.open
        else tasks.where(status: args['status'])
        end
        tasks = tasks.where(priority: args['priority']) if args['priority']
        tasks = tasks.search(args['query']) if args['query'].present?
        tasks = tasks.overdue if args['overdue']
        tasks = tasks.assigned_to(user.id) if args['assigned_to_me']
        rows, meta = paginate(tasks.by_priority, args)
        data = { rows: rows.map { |task| row(task) }, meta: meta }
        text = if rows.empty?
          'No tasks match.'
        else
          "#{rows.size} task#{'s' unless rows.size == 1}#{' (more available)' if meta[:has_more]}: " +
            rows.first(10).map { |t| "##{t.id} #{t.title} [#{t.status}, #{t.priority}#{", due #{t.due_on}" if t.due_on}]" }.join('; ')
        end
        result(text, data)
      end

      private

      def row(task)
        { id: task.id, title: task.title, description: task.description.to_s.first(500).presence, status: task.status, priority: task.priority,
          start_on: task.start_on&.iso8601, due_on: task.due_on&.iso8601, project: task.project&.name, project_id: task.project_id&.to_s,
          assignee: task.assignee&.display_name, labels: task.labels, blocked_reason: task.blocked_reason, updated_at: iso(task.updated_at) }
      end
    end
  end
end
