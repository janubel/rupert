# frozen_string_literal: true

module Mcp
  # Every MCP tool, in the order tools/list presents them.
  module Registry
    def self.tools
      [
        Tools::GetWorkspaceInfo, Tools::ListReports, Tools::SalesSummary, Tools::SalesTaxReport,
        Tools::InventorySearch, Tools::StockComparison, Tools::SwipesimpleItems, Tools::TimeKeepingReport, Tools::ListTasks,
        Tools::CreateTask, Tools::ListAlerts, Tools::AiHealth, Tools::SubmitFeedback, Tools::ListMyFeedback
      ]
    end

    def self.find(name)
      tools.find { |tool| tool.tool_name == name }
    end

    def self.available_to(token)
      tools.select { |tool| tool.available_to?(token) }
    end
  end
end
