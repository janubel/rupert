# frozen_string_literal: true

# A short machine-readable cause beside the human `reason`, so the Uploads
# insights can count why files wait or are refused without parsing sentences.
class AddReasonCodeToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :reason_code, :string
    add_index :uploads, %i[tenant_id reason_code], name: 'idx_uploads_reason_code'
  end
end
