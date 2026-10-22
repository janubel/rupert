# frozen_string_literal: true

module Mcp
  module Tools
    class ListTasks < Tool
      tool 'list_tasks',
        title: 'List tasks',
        description: 'Lists Rupert project tasks (the in-app Tasks board), most urgent first: title, status ' \
                     '(todo, in_progress, blocked, done), priority, due date, project and assignee. Filter by status, ' \
                     'priority, text, overdue, stock topic, or tasks assigned to the token owner. With topic=stock and ' \
                     'inventory access, an explicit sku:<SKU> task label links the product to per-platform/location stock. Paginated. Read-only.',
        scope: 'tasks:read'

      input_schema(
        type: 'object',
        properties: {
          status: { type: 'string', enum: Projects::Task::BOARD_STATUSES + ['open'], description: 'open = todo or in_progress. Default: every status except done.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES },
          query: { type: 'string', maxLength: 100, description: 'Text in the title or description.' },
          topic: { type: 'string', enum: %w[stock], description: 'Only stock, inventory-count and recount tasks.' },
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
        tasks = stock_topic(tasks) if args['topic'] == 'stock'
        tasks = tasks.overdue if args['overdue']
        tasks = tasks.assigned_to(user.id) if args['assigned_to_me']
        rows, meta = paginate(tasks.by_priority, args)
        meta[:total] = tasks.count
        data = { rows: rows.map { |task| row(task, include_stock: args['topic'] == 'stock') }, meta: meta,
                 path: Rails.application.routes.url_helpers.projects_tasks_path }
        text = if rows.empty?
          'No tasks match.'
        else
          "#{rows.size} task#{'s' unless rows.size == 1}#{' (more available)' if meta[:has_more]}: " +
            rows.first(10).map { |t| "##{t.id} #{t.title} [#{t.status}, #{t.priority}#{", due #{t.due_on}" if t.due_on}]" }.join('; ')
        end
        result(text, data)
      end

      private

      def row(task, include_stock: false)
        data = { id: task.id, title: task.title, description: task.description.to_s.first(500).presence, status: task.status, priority: task.priority,
          start_on: task.start_on&.iso8601, due_on: task.due_on&.iso8601, project: task.project&.name, project_id: task.project_id&.to_s,
          assignee: task.assignee&.display_name, labels: task.labels, blocked_reason: task.blocked_reason, updated_at: iso(task.updated_at) }
        data[:product] = linked_stock_product(task) if include_stock && user.can?('inventory.read')
        data
      end

      def stock_topic(tasks)
        terms = %w[stock inventory count recount]
        clauses = terms.map { "LOWER(tasks.title) LIKE ? OR LOWER(COALESCE(tasks.description, '')) LIKE ? OR LOWER(COALESCE(tasks.labels, '')) LIKE ?" }
        binds = terms.flat_map do |term|
          pattern = "%#{term}%"
          [pattern, pattern, pattern]
        end
        tasks.where("(#{clauses.join(') OR (')})", *binds)
      end

      def linked_stock_product(task)
        sku = Array(task.labels).filter_map { |label| label.to_s.match(/\Asku:(.+)\z/i)&.captures&.first }.first
        sku ||= "#{task.title} #{task.description}".match(/\bsku[:=#\s]+([a-z0-9_-]{2,100})/i)&.captures&.first
        return unless sku

        stock = StockEnrichment.for_skus([sku], include_alerts: user.can?('alerts.read'))[sku]
        return if stock.blank? || stock[:observations].empty?

        { sku: sku, name: stock[:observations].first[:name], low: stock[:low], observations: stock[:observations] }
      end
    end
  end
end
