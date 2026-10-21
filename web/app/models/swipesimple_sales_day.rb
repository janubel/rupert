# frozen_string_literal: true

# One day from SwipeSimple's Reporting -> sales CSV. Amounts are SwipeSimple's
# own figures; blank stays nil (unknown), never zero.
class SwipesimpleSalesDay < ApplicationRecord
  include TenantScoped

  validates :tenant_id, :merchant_account, :business_date, :source_digest, :pulled_at, presence: true
end
