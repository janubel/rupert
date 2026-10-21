# frozen_string_literal: true

# The latest SwipeSimple item list for one merchant account, as exported from
# SwipeSimple. Each import replaces the previous list after the whole file has
# been validated. Read-only evidence: nothing is written back to SwipeSimple.
class SwipesimpleItemSnapshot < ApplicationRecord
  include TenantScoped

  serialize :records_json, coder: JSON
  belongs_to :imported_by, class_name: 'User', optional: true

  validates :tenant_id, :merchant_account, :sha256, :captured_at, presence: true
  validates :merchant_account, uniqueness: { scope: :tenant_id }, length: { maximum: 120 }

  def records
    records_json.is_a?(Array) ? records_json : []
  end
end
