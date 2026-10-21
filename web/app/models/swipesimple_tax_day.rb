# frozen_string_literal: true

# One day x tax rate from SwipeSimple's Reporting -> tax CSV. Amounts are
# SwipeSimple's own figures; blank stays nil (unknown), never zero.
class SwipesimpleTaxDay < ApplicationRecord
  include TenantScoped

  validates :tenant_id, :merchant_account, :business_date, :tax_rate_label, :source_digest, :pulled_at, presence: true
end
