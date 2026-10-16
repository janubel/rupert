# frozen_string_literal: true

class DirectorySyncState < ApplicationRecord
  include TenantScoped

  validates :provider, inclusion: { in: %w[ctrax shopify] }
  validates :kind, inclusion: { in: %w[customers employees] }
  validates :status, inclusion: { in: %w[pending running success failed] }
end
