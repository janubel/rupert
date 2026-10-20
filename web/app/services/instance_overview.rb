# frozen_string_literal: true

# Read-only platform metrics. No provider checks, background work or host control.
class InstanceOverview
  WINDOW = 20

  def self.call(actor:, before_signup_id: nil)
    new(actor: actor, before_signup_id: before_signup_id).call
  end

  def initialize(actor:, before_signup_id: nil)
    @actor = actor
    @now = Time.current
    @before_signup_id = before_signup_id
  end

  def call
    authorize!
    requests = pending_signups
    {
      generated_at: @now, totals: totals, workspaces: workspaces,
      signups: requests.first(WINDOW), next_signup_cursor: requests.length > WINDOW ? requests[WINDOW - 1].id : nil,
      reviewed_signups: WorkspaceSignup.where(status: %w[approved rejected]).order(reviewed_at: :desc, id: :desc).limit(WINDOW).to_a,
      instance: instance, jobs: jobs, last_sync: last_sync, last_backup: last_backup,
      referral_domain: WorkspaceSignup::REFERRAL_DOMAIN,
      account_referrals: User.group(:referral_domain).order(Arel.sql('COUNT(*) DESC')).limit(10).count
    }
  end

  private

  def authorize!
    actor = @actor.is_a?(User) && @actor.persisted? && User.find_by(id: @actor.id, active: true, role: 'super_admin')
    raise ActiveRecord::RecordNotFound unless actor && Tenant.exists?(id: actor.tenant_id, status: 'active')
  end

  def totals
    workspace_counts = Tenant.group(:status).count
    signup_counts = WorkspaceSignup.group(:status).count
    {
      workspaces: workspace_counts.values.sum, active_workspaces: workspace_counts.fetch('active', 0),
      inactive_workspaces: workspace_counts.except('active').values.sum,
      accounts: User.count, active_accounts: User.where(active: true).count,
      new_accounts: User.where(created_at: (@now - 7.days)..@now).count,
      new_workspaces: Tenant.where(created_at: (@now - 30.days)..@now).count,
      pending_signups: signup_counts.fetch('pending', 0), approved_signups: signup_counts.fetch('approved', 0),
      rejected_signups: signup_counts.fetch('rejected', 0), allowed_domains: OauthAllowedDomain.unscoped.count,
      provider_setups: PosConnection.unscoped.count, issued_api_tokens: ApiAccessToken.unscoped.count,
      active_api_tokens: active_tokens.count
    }
  end

  def pending_signups
    rows = WorkspaceSignup.where(status: 'pending').order(id: :desc)
    if @before_signup_id.present?
      value = @before_signup_id.to_s
      raise ArgumentError, 'Invalid signup cursor' unless value.match?(/\A[1-9][0-9]{0,18}\z/) && value.to_i <= 9_223_372_036_854_775_807

      rows = rows.where('id < ?', value.to_i)
    end
    rows.limit(WINDOW + 1).to_a
  end

  def active_tokens
    ApiAccessToken.unscoped.joins(:user, :tenant).where(revoked_at: nil)
      .where('api_access_tokens.expires_at IS NULL OR api_access_tokens.expires_at > ?', @now)
      .where(users: { active: true }, tenants: { status: 'active' })
      .where('users.tenant_id = api_access_tokens.tenant_id')
  end

  def workspaces
    rows = Tenant.order(created_at: :desc, id: :desc).limit(WINDOW).to_a
    ids = rows.map(&:id)
    accounts = User.where(tenant_id: ids).group(:tenant_id).count
    domains = OauthAllowedDomain.unscoped.where(tenant_id: ids).group(:tenant_id).count
    setups = PosConnection.unscoped.where(tenant_id: ids).group(:tenant_id).count
    rows.map do |workspace|
      { workspace: workspace, accounts: accounts.fetch(workspace.id, 0),
        allowed_domains: domains.fetch(workspace.id, 0), provider_setups: setups.fetch(workspace.id, 0) }
    end
  end

  def instance
    connection = ApplicationRecord.connection
    result = { label: deployment_label, adapter: connection.adapter_name,
      schema_version: connection.select_value('SELECT MAX(version) FROM schema_migrations') }
    return result unless connection.adapter_name == 'SQLite'

    result[:sqlite_version] = connection.select_value('SELECT sqlite_version()')
    result[:journal_mode] = connection.select_value('PRAGMA journal_mode')
    database = connection.pool.db_config.database
    result[:main_database_bytes] = File.size(database) if database.present? && File.file?(database)
    result
  end

  def deployment_label
    value = ENV['RUPERT_INSTANCE_LABEL'].to_s.strip
    value.present? && value.length <= 80 && !value.match?(/[\x00-\x1f\x7f]/) ? value : 'Not configured'
  end

  def jobs
    { ready: SolidQueue::ReadyExecution.count, failed: SolidQueue::FailedExecution.count,
      recent_heartbeats: SolidQueue::Process.where(last_heartbeat_at: (@now - 2.minutes)..@now).count }
  end

  def last_sync
    SyncRun.unscoped.where(status: 'success').where.not(finishedAt: nil)
      .order(finishedAt: :desc, id: :desc).pick(:finishedAt)
  end

  def last_backup
    row = BackupLog.unscoped.where(tenant_id: nil, status: 'success').where.not(finishedAt: nil)
      .order(finishedAt: :desc, id: :desc).pick(:finishedAt, :fileSize)
    row && { finished_at: row[0], bytes: row[1] }
  end
end
