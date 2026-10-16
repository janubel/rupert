# frozen_string_literal: true

# Payment observations only: importing never creates sales or changes inventory.
class AuthorizeNetTransaction < ApplicationRecord
  include TenantScoped
  FINAL_STATUSES = %w[settledSuccessfully refundSettledSuccessfully voided declined expired generalError failedReview].freeze
end
