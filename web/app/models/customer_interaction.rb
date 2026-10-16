# frozen_string_literal: true

class CustomerInteraction < ApplicationRecord
  include TenantScoped
  include CustomerWorkspaceAssociations

  KINDS = %w[note call email meeting].freeze
  belongs_to :customer, class_name: 'Core::Customer'
  belongs_to :author, class_name: 'User', optional: true
  validates :kind, inclusion: { in: KINDS }
  validates :body, presence: true, length: { maximum: 10_000 }
  validates :author_id, presence: true
end
