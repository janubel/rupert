# frozen_string_literal: true

# Payment observations only: importing never creates sales or changes inventory.
class AuthorizeNetTransaction < ApplicationRecord
  include TenantScoped
  encrypts :invoice_number
  has_many :sale_links, class_name: 'AuthorizeNetSaleLink', dependent: :restrict_with_exception
  FINAL_STATUSES = %w[settledSuccessfully refundSettledSuccessfully voided declined expired generalError failedReview].freeze
end
