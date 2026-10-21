# frozen_string_literal: true

# In-app reports (the ladybug) and Buzz intake reuse agent_feedbacks. Each row
# now records where it came from and the Rupert Feedback task made for it, and
# whether a trusted sender marked it ready for development. Attachments
# (screenshot, page snapshot, logs, queries) live in their own admin-only table.
class AddReportFieldsToAgentFeedbacks < ActiveRecord::Migration[8.1]
  def change
    # SQLite, a small table: the constant default needs no staged backfill.
    safety_assured { add_column :agent_feedbacks, :source, :string, null: false, default: 'agent' }
    add_column :agent_feedbacks, :source_ref, :string
    add_column :agent_feedbacks, :source_sender, :string
    add_column :agent_feedbacks, :task_id, :bigint
    safety_assured { add_column :agent_feedbacks, :ready_for_development, :boolean, null: false, default: false }
    add_column :agent_feedbacks, :ready_marked_at, :datetime
    add_column :agent_feedbacks, :ready_marked_by, :string
    add_index :agent_feedbacks, %i[tenant_id user_id created_at], name: 'idx_agent_feedbacks_reporter'
    add_index :agent_feedbacks, %i[tenant_id source_ref], name: 'idx_agent_feedbacks_source_ref'
    add_index :agent_feedbacks, :task_id

    create_table :feedback_attachments do |t|
      t.string :tenant_id, null: false
      t.references :agent_feedback, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :content_type, null: false, default: 'text/plain'
      t.text :text_body
      t.binary :binary_body
      t.integer :byte_size, null: false, default: 0
      t.timestamps
      t.index %i[agent_feedback_id kind], unique: true, name: 'idx_feedback_attachments_kind'
      t.index :tenant_id
    end
  end
end
