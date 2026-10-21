# frozen_string_literal: true

# Feedback from external AI assistants connected over MCP (/mcp), plus a
# per-tool count of failed or denied tool calls so the owner sees where
# assistants get stuck even when they never write a report.
class CreateAgentFeedbacks < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_feedbacks do |t|
      t.string :tenant_id, null: false
      t.string :api_access_token_id
      t.bigint :user_id
      t.string :kind, null: false
      t.string :severity, null: false, default: 'normal'
      t.string :status, null: false, default: 'new'
      t.string :summary, null: false
      t.text :details
      t.string :related_tool
      t.string :related_reference
      t.string :agent_name
      t.string :agent_model
      t.text :context
      t.text :owner_notes
      t.bigint :triaged_by_id
      t.datetime :triaged_at
      t.timestamps
    end
    add_index :agent_feedbacks, %i[tenant_id created_at]
    add_index :agent_feedbacks, %i[tenant_id status]
    add_index :agent_feedbacks, :api_access_token_id

    create_table :agent_tool_issues do |t|
      t.string :tenant_id, null: false
      t.string :tool_name, null: false
      t.string :error_kind, null: false
      t.integer :occurrences, null: false, default: 0
      t.string :last_message
      t.string :last_api_access_token_id
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :agent_tool_issues, %i[tenant_id tool_name error_kind], unique: true, name: 'idx_agent_tool_issues_unique'
    add_index :agent_tool_issues, %i[tenant_id last_seen_at]
  end
end
