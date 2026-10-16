# frozen_string_literal: true

module Marketing
  class Record < ApplicationRecord
    self.abstract_class = true
    include TenantScoped
    validates :tenant_id, presence: true

    private

    def same_tenant(*names)
      names.each do |name|
        parent = public_send(name)
        errors.add(name, 'must belong to this workspace') unless parent && parent.tenant_id == tenant_id
      end
    end

    def https_fields(*names)
      names.each do |name|
        errors.add(name, 'must be a public HTTPS URL without credentials') unless Marketing::Urls.valid?(public_send(name))
      end
    end
  end
end
