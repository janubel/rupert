# frozen_string_literal: true

class AddGithubIssueToAgentFeedbacks < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_feedbacks, :github_issue_number, :integer
    add_column :agent_feedbacks, :github_issue_url, :string
    add_column :agent_feedbacks, :github_state, :string
    add_column :agent_feedbacks, :github_synced_at, :datetime
    add_index :agent_feedbacks, :github_issue_number
  end
end
