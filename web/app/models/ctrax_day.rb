# frozen_string_literal: true

class CtraxDay < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :reviewed_by, class_name: 'User', optional: true
  serialize :orders_json, coder: JSON
  serialize :sessions_json, coder: JSON
  serialize :controls_json, coder: JSON
  encrypts :orders_json, :sessions_json, :controls_json
  validates :business_date, :api_origin, :store_id, :timezone, :source_digest, :captured_at, presence: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :business_date, uniqueness: { scope: %i[tenant_id location_id] }
  validates :review_note, length: { maximum: 1000 }
  validate :workspace_matches

  def reviewed?
    reviewed_at.present? && reviewed_digest == source_digest
  end

  def orders
    orders_json.is_a?(Array) ? orders_json : []
  end

  def sessions
    sessions_json.is_a?(Array) ? sessions_json : []
  end

  def controls
    controls_json.is_a?(Hash) ? controls_json : {}
  end

  private

  def workspace_matches
    unless location && location.tenant_id == tenant_id && location.source == 'ctrax'
      errors.add(:location, 'must belong to this C-Trax workspace')
    end
    if reviewed_by && reviewed_by.tenant_id != tenant_id
      errors.add(:reviewed_by, 'must belong to this workspace')
    end
  end
end
