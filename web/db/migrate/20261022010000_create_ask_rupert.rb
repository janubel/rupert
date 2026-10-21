# frozen_string_literal: true

# Ask Rupert, the in-app help chat. Conversations and messages belong to one
# person and are deleted by the Clear button or the retention window. The usage
# ledger holds counters only (never message text) so the light rate limit still
# counts after someone clears a chat, and so administrators can see usage.
class CreateAskRupert < ActiveRecord::Migration[8.1]
  def change
    create_table :ask_rupert_conversations do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :title
      t.datetime :last_message_at
      t.timestamps
      t.index %i[tenant_id user_id last_message_at], name: 'idx_ask_rupert_conversations_owner'
    end

    create_table :ask_rupert_messages do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.references :conversation, null: false, foreign_key: { to_table: :ask_rupert_conversations }
      t.string :role, null: false
      t.string :status, null: false, default: 'done'
      t.text :content, null: false, default: ''
      t.text :links
      t.text :report_draft
      t.string :provider
      t.string :model
      t.string :page_path
      t.integer :tokens_in, null: false, default: 0
      t.integer :tokens_out, null: false, default: 0
      t.timestamps
      t.index %i[conversation_id id], name: 'idx_ask_rupert_messages_thread'
    end

    create_table :ask_rupert_usages do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :outcome, null: false, default: 'pending'
      t.string :provider
      t.string :model
      t.integer :tokens_in, null: false, default: 0
      t.integer :tokens_out, null: false, default: 0
      t.integer :tool_calls, null: false, default: 0
      t.integer :duration_ms
      t.timestamps
      t.index %i[tenant_id user_id created_at], name: 'idx_ask_rupert_usages_user'
      t.index %i[tenant_id created_at], name: 'idx_ask_rupert_usages_tenant'
    end
  end
end
