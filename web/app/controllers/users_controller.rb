# frozen_string_literal: true

# Store admins manage tenant employee roles. Only super admins can assign or
# modify a super admin account.
class UsersController < AuthenticatedController
  before_action :authorize_read, only: %i[index edit]
  before_action :authorize_write, except: %i[index edit]
  before_action :set_user, only: %i[edit update destroy deactivate activate update_permissions]
  before_action :guard_super_admin, only: %i[update destroy deactivate activate update_permissions]
  before_action :guard_role_assignment, only: %i[create update]

  def index
    @users = User.where(tenant_id: Current.tenant_id).ordered
    @roles = assignable_roles
  end

  def new
    @user = User.new(tenant_id: Current.tenant_id, role: 'employee')
    @roles = assignable_roles
  end

  def create
    @user = User.new({ role: 'employee' }.merge(user_params).merge(tenant_id: Current.tenant_id))
    if @user.save
      ActivityLogger.log('employee_added', subject: @user, details: @user.role)
      redirect_to(users_path, notice: "#{@user.display_name} added.")
    else
      @roles = assignable_roles
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    @roles = assignable_roles
    @catalog = User.permission_catalog
  end

  # Replace an employee's per-person permission overrides. Empty selection
  # clears them, falling back to the role's permissions.
  def update_permissions
    if @user.employee?
      return redirect_to(edit_user_path(@user), alert: 'Employee access is fixed to POS and their own time records.')
    end

    raw = params[:permissions]
    permissions = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h.keys : []
    @user.update_permission_overrides!(permissions)
    ActivityLogger.log('employee_permissions', subject: @user, details: permissions.join(', '))
    redirect_to(edit_user_path(@user), notice: "Permissions updated for #{@user.display_name}.")
  end

  def update
    if @user.update(user_params)
      ActivityLogger.log('employee_updated', subject: @user, details: @user.role)
      employee = People::Employee.find_by(id: params[:return_employee_id], user_id: @user.id) if params[:return_employee_id].present?
      redirect_to(employee ? people_employee_path(employee, anchor: 'access') : users_path, notice: "#{@user.display_name} updated.")
    else
      @roles = assignable_roles
      render(:edit, status: :unprocessable_entity)
    end
  end

  def destroy
    return redirect_to(users_path, alert: "You can't remove your own account.") if @user == Current.user

    @user.destroy
    ActivityLogger.log('employee_removed', subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} removed.")
  end

  def deactivate
    return redirect_to(users_path, alert: "You can't deactivate your own account.") if @user == Current.user

    @user.update!(active: false)
    ActivityLogger.log('employee_deactivated', subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} deactivated.")
  end

  def activate
    @user.update!(active: true)
    ActivityLogger.log('employee_reactivated', subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} reactivated.")
  end

  private

  def authorize_read
    authorize(:module, :users_read?)
  end

  def authorize_write
    raise Pundit::NotAuthorizedError unless Current.user&.can_manage_accounts?

    authorize(:module, :users_write?)
  end

  def set_user
    @user = User.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  # Non-super-admins can't modify or deactivate a super admin account.
  def guard_super_admin
    return if Current.user.super_admin?

    redirect_to(users_path, alert: 'Only the super admin can modify a super admin account.') if @user.super_admin?
  end

  def user_params
    permitted = params.require(:user).permit(:name, :email, :password, :active, :role)
    permitted.delete(:role) if permitted[:role].blank?
    permitted
  end

  def assignable_roles
    Current.user.super_admin? ? User.roles.keys : User.roles.keys.excluding('super_admin')
  end

  def guard_role_assignment
    role = params.dig(:user, :role)
    return if role.blank? || assignable_roles.include?(role)

    redirect_to users_path, alert: 'Choose an allowed employee role. Only a super admin can assign the super admin role.'
  end
end
