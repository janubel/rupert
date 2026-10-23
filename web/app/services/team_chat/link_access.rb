# frozen_string_literal: true

require 'uri'

module TeamChat
  # Destination checks only; never requests a page or runs a controller action.
  # Record lookups stay inside the current tenant even for platform administrators.
  class LinkAccess
    POLICY_RECORDS = {
      'projects/tasks' => ['Projects::Task', 'Projects::TaskPolicy'],
      'projects/projects' => ['Projects::Project', 'Projects::ProjectPolicy'],
      'people/timesheets' => ['People::Timesheet', 'People::TimesheetPolicy'],
      'people/pay_runs' => ['People::PayRun', 'People::PayRunPolicy'],
      'people/leave_requests' => ['People::LeaveRequest', 'People::LeaveRequestPolicy'],
      'people/employees' => ['People::Employee', 'People::EmployeePolicy'],
      'goals/goals' => ['Goals::Goal', 'Goals::GoalPolicy'],
      'goals/kpis' => ['Goals::Kpi', 'Goals::KpiPolicy'],
      'customers' => ['Core::Customer', 'CustomerPolicy']
    }.freeze
    READ_RECORDS = {
      'orders' => ['Core::Order', 'sales.read'], 'uploads' => ['Upload', 'uploads.read'],
      'shopify_variants' => ['ShopifyVariant', 'inventory.read'],
      'bank_statements' => ['ReconciliationDocument', 'finance.read']
    }.freeze
    REPORT_ACTIONS = %w[index sales sales_tax financial inventory operations register_summary].freeze

    def initialize(user)
      @user = User.find_by(id: user&.id, tenant_id: Current.tenant_id) if Current.tenant_id.present?
      @decisions = {}
    end

    def allowed?(path)
      return false unless @user&.active? && @user.tenant_id == Current.tenant_id

      @decisions.fetch(path) { @decisions[path] = destination_allowed?(path) }
    end

    private

    def destination_allowed?(path)
      uri = URI.parse(path)
      route = Rails.application.routes.recognize_path(uri.path, method: :get)
      return false if route[:format].present? && !%w[html csv pdf].include?(route[:format])
      return true if page_paths.include?(uri.path)

      controller, action = route.values_at(:controller, :action)
      if controller == 'reports'
        return @user.can?('reports.read') && REPORT_ACTIONS.include?(action)
      elsif controller == 'learning'
        return true if %w[index welcome].include?(action)
        return action == 'show' && LearningCatalog.available(@user).any? { |lesson| lesson[:key] == route[:id] }
      elsif controller == 'team_chat'
        return chat_allowed?(route)
      elsif controller == 'feedback_reports'
        scope = FeedbackAttachment.viewable_by?(@user) ? AgentFeedback.all : AgentFeedback.reported_by(@user)
        return false unless %w[show screenshot].include?(action) && scope.where(tenant_id: @user.tenant_id, id: route[:id]).exists?

        return action == 'show' || FeedbackAttachment.viewable_by?(@user)
      elsif controller == 'receipts'
        return action == 'show' && PurchaseReceipt.visible_to(@user).where(tenant_id: @user.tenant_id, id: route[:id]).exists?
      end
      if (rule = POLICY_RECORDS[controller])
        model = rule.first.constantize
        return rule.last.constantize.new(@user, model).index? if action == 'index'

        record = model.find_by(tenant_id: @user.tenant_id, id: route[:id])
        return false unless record

        policy = rule.last.constantize.new(@user, record)
        if controller == 'projects/tasks' && action == 'approved_request'
          return policy.show? && approval_matches?(record, uri.query)
        end
        return %w[show edit].include?(action) && policy.public_send("#{action}?")
      end
      if (rule = READ_RECORDS[controller])
        return action == 'show' && @user.can?(rule.last) && rule.first.constantize.where(tenant_id: @user.tenant_id, id: route[:id]).exists?
      end
      false
    rescue URI::InvalidURIError, ActionController::RoutingError, ArgumentError
      false
    end

    def page_paths
      @page_paths ||= AskRupert::Guide.new(@user).permitted_pages.map { |page| URI.parse(page.path).path }.to_set
    end

    def chat_allowed?(route)
      return false unless TeamChat.allowed?(@user) && %w[show attachment media].include?(route[:action])

      room = Room.find_by(tenant_id: @user.tenant_id, slug: route[:room])
      return false unless room&.visible_to?(@user)
      return true unless route[:action] == 'attachment'

      Attachment.where(tenant_id: @user.tenant_id, room_id: room.id, id: route[:id]).exists?
    end

    def approval_matches?(task, query)
      id = Rack::Utils.parse_nested_query(query.to_s)['approval_id']
      return false unless id.is_a?(String)

      approval = Approval.find_by(tenant_id: @user.tenant_id, public_id: id, state: 'done')
      approval && %w[create_task update_task].include?(approval.proposal['tool']) &&
        approval.events.find_by(kind: 'executed')&.details&.dig('result', 'id').to_s == task.id.to_s
    rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
      false
    end
  end
end
