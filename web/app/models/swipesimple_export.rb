# frozen_string_literal: true

class SwipesimpleExport < ApplicationRecord
  include TenantScoped

  encrypts :original_csv
  belongs_to :imported_by, class_name: 'User', optional: true
  has_many :report_rows, class_name: 'SwipesimpleReportRow', dependent: :restrict_with_exception
  validates :tenant_id, :merchant_account, :fingerprint, :sha256, :exported_at, presence: true
  validates :kind, inclusion: { in: %w[transactions invoices] }
end
