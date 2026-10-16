# frozen_string_literal: true

# Labels come from the same effective grants and registry as navigation.
class EmployeeAccessReview
  def initialize(employee)
    @employee, @user = employee, employee.user
  end

  def status
    return 'No login' unless @user
    return 'Login disabled' unless @user.active?

    @user.role.humanize
  end

  def tabs
    return [] unless @user&.active? && @user.tenant_id == @employee.tenant_id

    personal = [
      { name: 'Today', level: 'Own time' }, { name: 'Timesheets', level: 'Own · submit' },
      { name: 'Time off', level: 'Own · request' }, { name: 'Reports & pay', level: 'Own · view / report' }
    ]
    if @user.employee?
      return (@user.can_use_pos? ? [{ name: 'POS', level: 'Checkout' }] : []) + personal
    end

    ModuleRegistry.nav_for(@user).map do |entry|
      level = if %w[ctrax_pos point_of_sale].include?(entry.key)
        'Checkout'
      elsif entry.key == 'time_clock'
        'Own time'
      elsif entry.key == 'timesheets' && !@user.can?('timesheets.read')
        'Own · submit'
      elsif entry.key == 'employee_reports'
        'Review / reply'
      else
        grants = Array(entry.permission)
        writes = grants.filter_map { |permission| permission.end_with?('.read') ? permission.sub(/\.read\z/, '.write') : (permission if permission.end_with?('.write')) }
        writes.any? { |permission| @user.can?(permission) } ? 'Edit' : 'View'
      end
      { name: entry.name, level: level }
    end + [{ name: 'My time', level: 'Own records' }]
  end

  def summary
    return [] unless @user&.active?
    return tabs if @user.employee?

    ModuleRegistry.areas_for(@user).map { |area| { name: area[:name], level: 'Open' } }
  end
end
