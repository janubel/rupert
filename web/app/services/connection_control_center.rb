# frozen_string_literal: true

# Presence, checks and repair guidance only: no credential values or vendor calls.
class ConnectionControlCenter
  SOURCE_SETUP = { 'ctrax' => 'ctrax', 'swipesimple' => 'swipesimple',
    'authorize_net' => 'authorize_net_reporting', 'bank' => 'iris_reporting' }.freeze
  NEXT_STEPS = {
    'Needs access' => 'Open setup, obtain the correct account access, save credentials, then check read access.',
    'Needs login' => 'Open login setup, restore website sign-in and complete any additional verification with the vendor.',
    'Needs connection' => 'Ask the platform operator to complete the approved backup connection.',
    'Paused' => 'Review the saved account and access check. Enable its schedule only when you intend automatic reads.',
    'Error' => 'Open setup and review its last check. Recheck access before retrying a read.',
    'Stale' => 'Try one read after checking access. If it stays stale, ask the operator to inspect the job worker and schedule.',
    'Stale snapshot' => 'Import a fresh portal export. A portal snapshot is not an automatic connection.',
    'Stale export' => 'Obtain a fresh supported export and check delivery. Re-importing an old file does not refresh its source time.',
    'Portal snapshot' => 'Import a fresh export when needed. Approved API access is separate from portal sign-in.',
    'Portal imports' => 'Continue manual imports or obtain approved reporting API access before enabling automatic reads.',
    'Awaiting pull' => 'Run one read and confirm a new source timestamp before relying on its schedule.',
    'Awaiting files' => 'Check the approved file producer and delivery; the local inbox cannot create vendor exports.',
    'Awaiting backup' => 'The platform operator can run and verify the first backup from Backup settings.',
    'Needs feed' => 'Use manual exports until the vendor provides an approved automatic feed.',
    'Syncing' => 'A read is in progress. Refresh later before queuing another attempt.',
    'Backing up' => 'A backup is in progress. The platform operator can review its result in Backup settings.',
    'Live' => 'Source evidence is current. Review coverage and reconciliation separately.',
    'Healthy' => 'A recent backup succeeded. A restore drill is still needed to prove recovery.'
  }.freeze

  def self.platform_admin?
    User.exists?(id: Current.user&.id, active: true, role: 'super_admin')
  end

  def self.sources
    SourceSyncStatus.all(include_platform: platform_admin?).map do |source|
      source.slice(:key, :label, :badge, :last_at, :schedule, :ready, :mode).merge(
        next_step: NEXT_STEPS.fetch(source[:badge], 'Open setup and review the source before retrying.'))
    end
  end

  def self.services
    legacy = ConnectionsGuide::SERVICES.reject { |service| service.key == 'sync' || (service.key == 'google_drive' && !platform_admin?) }
    legacy.map { |service| managed(service) } + PosProviderCatalog.all.reject { |provider| %w[shopify square].include?(provider[:key]) }.map do |provider|
      provider_setup(provider)
    end
  end

  def self.managed(service)
    fields = ConnectionCredentials.fields(service.key)
    keys = service.keys.map do |key|
      field = fields.find { |entry| entry[:key] == key }
      { key: key, label: field&.fetch(:label) || key.humanize, optional: field&.fetch(:optional) || false }.merge(presence(key))
    end
    required = keys.reject { |key| key[:optional] }
    state = if keys.any? { |key| key[:unreadable] }
      'Credentials unreadable'
    elsif required.all? { |key| key[:set] }
      'Configured'
    elsif keys.any? { |key| key[:set] }
      'Partially set up'
    else
      'Not configured'
    end
    { key: service.key, name: service.name, description: service.description, kind: 'managed', fields: keys,
      state: state, checked_at: nil, find_url: service.find_url, find_hint: service.find_hint, renewal_note: service.renewal_note }
  end
  private_class_method :managed

  def self.presence(key)
    { set: EnvStore.effective(key).present?, unreadable: false,
      source: Setting.exists?(key: key, tenant_id: EnvStore::PLATFORM_KEYS.include?(key) ? nil : Current.tenant_id) ? 'Saved in Rupert' : 'Hosting configuration' }
  rescue ActiveRecord::Encryption::Errors::Decryption
    { set: false, unreadable: true, source: 'Ask the platform operator to restore the encryption keys' }
  end
  private_class_method :presence

  def self.provider_setup(provider)
    connection = PosConnection.find_by(provider: provider[:key]) || PosConnection.new(provider: provider[:key])
    values = connection.credential_values
    fields = connection.credential_keys.map { |key| { key: key, label: key.humanize, optional: false, set: values[key].present?, unreadable: false, source: 'Saved in Rupert' } }
    { key: provider[:key], name: provider[:name], description: provider[:description], kind: 'provider', fields: fields,
      state: connection.status_label, checked_at: connection.last_checked_at, find_url: provider[:website],
      find_hint: provider[:instructions], renewal_note: nil,
      checkable: connection.persisted? && connection.vendor_approved && connection.credentials_saved? &&
        (connection.check_kind.present? || %w[authorize_net_reporting iris_reporting swipesimple].include?(provider[:key])) }
  rescue ActiveRecord::Encryption::Errors::Decryption
    { key: provider[:key], name: provider[:name], description: provider[:description], kind: 'provider', fields: [],
      state: 'Credentials unreadable', find_url: provider[:website], find_hint: 'Ask the platform operator to restore encryption keys before changing this setup.',
      checkable: false }
  end
  private_class_method :provider_setup
end
