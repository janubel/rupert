# frozen_string_literal: true

# User is deliberately not TenantScoped. Every project/task people lookup must
# supply the work's tenant, including validation outside an HTTP request.
module ProjectsPeople
  extend ActiveSupport::Concern

  class_methods do
    def available_people
      User.where(tenant_id: Current.tenant_id).active.ordered
    end
  end

  private

  def validate_project_person(attribute)
    value = public_send(attribute)
    return if value.blank?

    people = User.where(tenant_id: tenant_id || Current.tenant_id, id: value)
    # Keep historical assignments when an account is deactivated, but do not
    # allow a new assignment to an inactive account.
    people = people.active if new_record? || will_save_change_to_attribute?(attribute)
    errors.add(attribute, 'must be an active person in this workspace') unless people.exists?
  end
end
