# frozen_string_literal: true

module CustomerWorkspaceAssociations
  extend ActiveSupport::Concern

  included do
    validate :customer_associations_belong_to_workspace
  end

  private

  def customer_associations_belong_to_workspace
    { customer_id: Core::Customer, author_id: User, owner_id: User }.each do |key, model|
      next unless has_attribute?(key) && self[key].present?
      next if model.unscoped.exists?(id: self[key], tenant_id: tenant_id)

      errors.add(key, 'must belong to this workspace')
    end
  end
end
