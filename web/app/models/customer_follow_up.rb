# frozen_string_literal: true

class CustomerFollowUp < ApplicationRecord
  include TenantScoped
  include CustomerWorkspaceAssociations

  belongs_to :customer, class_name: 'Core::Customer'
  belongs_to :author, class_name: 'User', optional: true
  belongs_to :owner, class_name: 'User', optional: true
  validates :title, presence: true, length: { maximum: 500 }
  validates :due_on, :author_id, presence: true
  scope :open, -> { where(completed_at: nil) }
  scope :due, -> { open.where(due_on: ..Date.current) }
end
