# frozen_string_literal: true

class InventoryCountScanReceipt < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.record_timestamps = true

  belongs_to :count, class_name: 'InventoryCount'
  serialize :result, coder: JSON
end
