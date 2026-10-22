# frozen_string_literal: true

class CreateChatApprovals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_runs, :request_context, :json
    create_table :chat_approvals do |t|
      t.string :tenant_id, null: false
      t.references :message, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.bigint :source_message_id, null: false
      t.string :public_id, null: false
      t.string :state, null: false, default: 'proposed'
      t.string :decision
      t.string :decided_by_id
      t.string :decided_by_name
      t.datetime :decided_at
      t.json :proposal, null: false, default: {}
      t.json :provenance, null: false, default: {}
      t.json :receipt, null: false, default: {}
      t.timestamps
      t.index [:tenant_id, :source_message_id, :public_id], unique: true, name: 'index_chat_approvals_identity'
    end
    create_table :chat_approval_events do |t|
      t.string :tenant_id, null: false
      t.references :approval, null: false, foreign_key: { to_table: :chat_approvals }
      t.string :kind, null: false
      t.string :actor_id
      t.string :actor_name
      t.json :details, null: false, default: {}
      t.datetime :created_at, null: false
    end
  end
end
