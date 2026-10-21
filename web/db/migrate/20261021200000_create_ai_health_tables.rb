# frozen_string_literal: true

# Health of Rupert's opencode integration. Instance-wide on purpose (one
# opencode key and one agent process per server, like Solid Queue), so these
# rows carry no tenant. They hold classifications and counters only — never the
# API key, prompts or replies.
class CreateAiHealthTables < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_health_checks do |t|
      t.string :provider, null: false, default: 'opencode'
      t.string :triggered_by, null: false, default: 'scheduled'
      t.string :status, null: false
      t.string :key_state, null: false, default: 'unchecked'
      t.string :error_type
      t.string :error_code
      t.integer :http_status
      t.integer :latency_ms
      t.integer :catalog_latency_ms
      t.boolean :rate_limited, null: false, default: false
      t.integer :retry_after_seconds
      t.string :configured_model
      t.string :model_state, null: false, default: 'unknown'
      t.text :free_models
      t.integer :free_model_count, null: false, default: 0
      t.integer :catalog_size
      t.datetime :checked_at, null: false
      t.timestamps
    end
    add_index :ai_health_checks, :checked_at

    create_table :ai_agent_runs do |t|
      t.string :agent, null: false, default: 'buzz'
      t.string :model
      t.string :outcome, null: false
      t.string :error_type
      t.integer :tokens_in, null: false, default: 0
      t.integer :tokens_out, null: false, default: 0
      t.integer :tokens_reasoning, null: false, default: 0
      t.integer :cache_read_tokens, null: false, default: 0
      t.integer :cache_write_tokens, null: false, default: 0
      t.decimal :cost_usd, precision: 12, scale: 6
      t.integer :steps, null: false, default: 0
      t.integer :duration_ms
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :ai_agent_runs, :occurred_at
  end
end
