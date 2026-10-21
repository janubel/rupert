# frozen_string_literal: true

# The Uploads inbox: every file someone sends to Rupert (browser, API or host
# drop directory) lands here first. The original bytes are kept exactly once,
# encrypted, and never change; recognition, dry-runs and approvals only add
# columns of state around them. Nothing in this table changes a business record.
class CreateUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :uploads do |t|
      t.string :tenant_id, null: false
      t.string :status, null: false, default: 'received'
      t.string :origin, null: false, default: 'web'
      t.string :filename, null: false
      t.string :client_content_type
      t.string :file_format
      t.integer :byte_size, null: false, default: 0
      t.string :sha256
      t.boolean :retained, null: false, default: false
      t.text :content_base64
      t.integer :duplicate_of_id
      t.string :detected_type
      t.string :detected_label
      t.integer :confidence
      t.text :detected_reason
      t.string :source_guess
      t.text :candidates_json
      t.string :importer_key
      t.boolean :operator_chosen, null: false, default: false
      t.text :params_json
      t.integer :row_count
      t.text :reason
      t.text :summary_json
      t.string :dry_run_digest
      t.datetime :dry_run_at
      t.string :dry_run_by_name
      t.string :recognizer_version
      t.datetime :recognized_at
      t.integer :uploaded_by_id
      t.string :uploaded_by_name
      t.string :via_token_label
      t.datetime :imported_at
      t.integer :imported_by_id
      t.string :imported_by_name
      t.string :result_path
      t.datetime :discarded_at
      t.string :discarded_by_name
      t.timestamps
      t.index %i[tenant_id created_at], name: 'idx_uploads_recent'
      t.index %i[tenant_id status], name: 'idx_uploads_status'
      t.index %i[tenant_id sha256], unique: true, where: 'retained = 1', name: 'idx_uploads_retained_replay'
      t.index :duplicate_of_id
      t.index :tenant_id
    end
  end
end
