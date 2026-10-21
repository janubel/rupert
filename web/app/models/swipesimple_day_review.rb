# frozen_string_literal: true

# Who reviewed a SwipeSimple business day in Rupert, and against which version
# of the export evidence. It does not close anything at SwipeSimple or NAB.
class SwipesimpleDayReview < ApplicationRecord
  include TenantScoped
  belongs_to :reviewed_by, class_name: 'User'
  validates :business_date, :reviewed_at, :reviewed_digest, presence: true
  validates :business_date, uniqueness: { scope: :tenant_id }
  validates :review_note, length: { maximum: 1000 }
  validate :reviewer_in_workspace

  private

  def reviewer_in_workspace
    errors.add(:reviewed_by, 'must belong to this workspace') if reviewed_by && reviewed_by.tenant_id != tenant_id
  end
end
