# frozen_string_literal: true

class PurchaseReceiptEvent < ApplicationRecord
  include TenantScoped
  encrypts :snapshot_json, :note
  belongs_to :purchase_receipt
  belongs_to :actor, class_name: 'User'
  validates :action, :snapshot_json, presence: true
  validates :note, length: { maximum: 4000 }
  before_update { throw :abort }
  before_destroy { throw :abort }
end
