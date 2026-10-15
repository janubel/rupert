# frozen_string_literal: true

# Role × permission matrix. Per-tenant overrides in role_permissions replace
# the built-in defaults for a role; an empty set means "use built-ins". Reset
# clears the overrides so a role falls back to the defaults.
class PermissionsController < AuthenticatedController
  before_action :authorize_read, only: :show
  before_action :authorize_write, only: %i[save reset]

  def show
    @roles = User.roles.keys
    @catalog = User.permission_catalog
    @overrides = RolePermission.where(tenant_id: Current.tenant_id)
                               .index_by do |rp|
      [rp.role,
       rp.permission]
    end
    @builtin = User::ROLE_PERMISSIONS
  end

  def save
    valid_roles = User.roles.keys
    params[:roles].to_unsafe_h.each do |role, perms|
      next unless valid_roles.include?(role.to_s)

      enabled = perms.is_a?(Hash) ? perms.keys : Array(perms)
      RolePermission.where(tenant_id: Current.tenant_id, role: role).delete_all
      enabled.each do |permission|
        next unless User.all_permissions.include?(permission)

        RolePermission.create!(tenant_id: Current.tenant_id, role: role, permission: permission, enabled: true)
      end
    end
    ActivityLogger.log('role_permissions_saved', details: 'role overrides updated')
    redirect_to(permissions_path, notice: 'Permissions saved.')
  end

  def reset
    RolePermission.where(tenant_id: Current.tenant_id).delete_all
    ActivityLogger.log('role_permissions_reset', details: 'cleared to defaults')
    redirect_to(permissions_path, notice: 'Permissions reset to defaults.')
  end

  private

  def authorize_read
    authorize(:module, :users_read?)
  end

  def authorize_write
    raise Pundit::NotAuthorizedError unless Current.user&.can_manage_accounts?

    authorize(:module, :users_write?)
  end
end
