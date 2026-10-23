# frozen_string_literal: true

require 'digest'

class User < ActiveRecord::Base
  has_secure_password

  belongs_to :tenant, optional: true
  has_many :user_permissions, dependent: :destroy
  has_many :api_access_tokens, dependent: :destroy
  has_many :google_login_identities, dependent: :destroy

  serialize :dashboard_config, coder: JSON

  validates :email,
    presence: true,
    uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name, :email) }

  enum :role,
    {
      super_admin: 'super_admin',
      admin: 'admin',
      manager: 'manager',
      shift_leader: 'shift_leader',
      cashier: 'cashier',
      inventory_employee: 'inventory_employee',
      reporting: 'reporting',
      reader: 'reader',
      employee: 'employee'
    },
    default: :employee

  # Permission matrix. "*" grants everything.
  ROLE_PERMISSIONS = {
    'super_admin' => ['*'],
    'admin' => [
      'chat.use',
      'marketing.read',
      'marketing.write',
      'marketing.review',
      'marketing.contacts',
      'marketing.discounts',
      'dashboard.read',
      'sales.read',
      'sales.write',
      'customers.read',
      'customers.write',
      'inventory.read',
      'inventory.write',
      'reconcile.read',
      'reconcile.write',
      'reports.read',
      'reports.write',
      'ledger.read',
      'ledger.write',
      'projects.read',
      'projects.write',
      'alerts.read',
      'alerts.write',
      'sync.read',
      'sync.write',
      'settings.read',
      'settings.write',
      'system.read',
      'system.write',
      'users.read',
      'users.write',
      'purchasing.read',
      'purchasing.write',
      'finance.read',
      'finance.write',
      'uploads.read',
      'uploads.write',
      'hr.read',
      'hr.write',
      'timesheets.read',
      'timesheets.write',
      'leave.read',
      'leave.write',
      'payroll.read',
      'payroll.write'
    ],
    'manager' => [
      'receipts.review',
      'dashboard.read',
      'sales.read',
      'customers.read',
      'customers.write',
      'inventory.read',
      'inventory.write',
      'reconcile.read',
      'ledger.read',
      'reports.read',
      'projects.read',
      'projects.write',
      'alerts.read',
      'alerts.write',
      'sync.read',
      'hr.read',
      'timesheets.read',
      'timesheets.write',
      'leave.read',
      'leave.write'
    ],
    'shift_leader' => %w[dashboard.read pos.use timesheets.read timesheets.review],
    'employee' => %w[pos.use timesheets.self tasks.self],
    'cashier' => [
      'dashboard.read',
      'sales.read',
      'sales.write',
      'customers.read',
      'inventory.read',
      'alerts.read'
    ],
    'reader' => [
      'dashboard.read',
      'sales.read',
      'customers.read',
      'inventory.read',
      'reconcile.read',
      'reports.read',
      'ledger.read',
      'alerts.read'
    ],
    'inventory_employee' => %w[dashboard.read inventory.read inventory.write reconcile.read alerts.read alerts.write],
    'reporting' => %w[dashboard.read sales.read inventory.read reports.read ledger.read]
  }.freeze

  def can?(permission)
    return true if permission.to_s == 'timesheets.self' && (effective_permissions.include?('timesheets.read') || TimeClockService.worker_for(self))
    perms = effective_permissions
    perms.include?('*') || perms.include?(permission.to_s)
  end

  def can_review_receipts?
    active? && (can?('receipts.review') || can?('finance.write'))
  end

  def can_review_timesheets?
    active? && can?('timesheets.read') && (can?('timesheets.review') || can?('timesheets.write'))
  end

  # POS access does not grant sales history, reports or inventory management.
  def can_use_pos?
    active? && (can?('pos.use') || %w[sales.read sales.write inventory.read].all? { |permission| can?(permission) })
  end

  def permissions_signature
    Digest::SHA256.hexdigest(effective_permissions.sort.join('|'))
  end

  # Account and role administration cannot be delegated to ordinary staff.
  # Re-reads the account (it must be active right now), once per loaded user.
  def can_manage_accounts?
    return @can_manage_accounts if defined?(@can_manage_accounts)

    actor = User.find_by(id: id, active: true)
    @can_manage_accounts = !!(actor && (actor.admin? || actor.super_admin?) && actor.can?('users.write'))
  end

  def active?
    active != false
  end

  # Clear the memoized permission list on reload so fresh data always applies.
  def reload(*args)
    @effective_permissions = nil
    remove_instance_variable(:@can_manage_accounts) if defined?(@can_manage_accounts)
    super
  end

  # Permissions in effect for this user. Resolution order, highest to lowest:
  #   1. per-employee overrides (user_permissions)   — exact list for that person
  #   2. per-role overrides (role_permissions)       — replaces built-ins for role
  #   3. built-in ROLE_PERMISSIONS matrix
  def effective_permissions
    # Employee sign-in is a self-service boundary, including when stale or
    # mistaken person/role overrides contain wider permissions or a wildcard.
    return ROLE_PERMISSIONS.fetch('employee') if employee?

    @effective_permissions = nil if @effective_permissions_role != role
    @effective_permissions_role = role
    @effective_permissions ||= if super_admin?
      ['*']
    else
      person = user_permissions
      if person.any?
        person.select(&:enabled?).map(&:permission)
      else
        overrides = RolePermission.where(tenant_id: tenant_id, role: role)
        overrides.empty? ? ROLE_PERMISSIONS.fetch(role, []) : overrides.select(&:enabled?).map(&:permission)
      end
    end
  end

  # True when this user has any per-employee permission overrides.
  def permission_overrides?
    user_permissions.any?
  end

  # Replace this user's per-employee permission overrides with the given list.
  # An empty list removes all overrides (falls back to role permissions).
  def update_permission_overrides!(permissions)
    if employee? && (permissions.to_a - ROLE_PERMISSIONS.fetch('employee')).any?
      raise ArgumentError, 'Staff access is limited to POS, their own time records and assigned tasks.'
    end
    @effective_permissions = nil
    user_permissions.reset
    user_permissions.delete_all
    permissions.to_a.each do |permission|
      next unless User.all_permissions.include?(permission)

      user_permissions.create!(permission: permission, tenant_id: tenant_id, enabled: true)
    end
  end

  def display_name
    name.presence || email.to_s.split('@').first.to_s.titleize
  end

  # Dashboard widget configuration as a hash (see DashboardWidget).
  def dashboard_config_hash
    value = dashboard_config
    value.is_a?(Hash) ? value : {}
  end

  # Permission catalog grouped by module area, used by the Permissions screen
  # and to keep the role matrix in one place.
  def self.permission_catalog
    [
      { area: 'Receipts', permissions: ['receipts.review'] },
      { area: 'Overview', permissions: ['dashboard.read'] },
      # Ask Rupert, the in-app help chat. Administrators by default; delegate it per role or person.
      { area: 'Rupert Chat', permissions: ['chat.use'] },
      { area: 'Marketing', permissions: ['marketing.read', 'marketing.write', 'marketing.review', 'marketing.contacts', 'marketing.discounts'] },
      {
        area: 'Commerce',
        permissions: ['pos.use', 'sales.read', 'sales.write', 'customers.read', 'customers.write', 'inventory.read',
                      'inventory.write']
      },
      {
        area: 'Operations',
        permissions: ['reconcile.read', 'reconcile.write', 'reports.read', 'reports.write', 'ledger.read',
                      'ledger.write', 'projects.read', 'projects.write', 'tasks.self']
      },
      {
        area: 'System',
        permissions: ['alerts.read', 'alerts.write', 'sync.read', 'sync.write', 'settings.read', 'settings.write',
                      'system.read', 'system.write', 'purchasing.read', 'purchasing.write', 'finance.read', 'finance.write',
                      'uploads.read', 'uploads.write']
      },
      {
        area: 'Team',
        permissions: ['users.read', 'users.write', 'hr.read', 'hr.write', 'timesheets.read', 'timesheets.write', 'timesheets.review', 'timesheets.self',
                      'leave.read', 'leave.write', 'payroll.read', 'payroll.write']
      }
    ]
  end

  def self.all_permissions
    permission_catalog.flat_map { |group| group[:permissions] }
  end
end
