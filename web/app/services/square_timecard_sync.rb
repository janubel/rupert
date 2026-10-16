# frozen_string_literal: true

# Explicit tenant opt-in; scheduling never creates or promotes an account.
class SquareTimecardSync
  KEY = 'square_timecards_schedule'

  def self.configuration
    JSON.parse(Setting.find_by(tenant_id: Current.tenant_id, key: KEY)&.value || '{}')
  rescue JSON::ParserError
    {}
  end

  def self.enabled?
    configuration['enabled'] == true
  end

  def self.configure!(enabled:, actor: Current.user)
    Tenant.transaction do
      raise Pundit::NotAuthorizedError unless Current.tenant&.status == 'active'
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      actor = authorized_actor(actor&.id)
      raise Pundit::NotAuthorizedError unless actor
      EnvStore.clear_cache!
      raise SquareTimecardReader::Error, 'Configure the Square connection first.' if enabled && !SquareClient.configured?

      Setting.find_or_create_for(KEY, Current.tenant_id) do |setting|
        setting.value = { enabled: enabled == true, actor_id: actor.id, version: SecureRandom.hex(24) }.to_json
      end
      ActivityLogger.log('square_timecards_schedule_updated', details: enabled ? 'Read-only refresh every 15 minutes enabled.' : 'Automatic refresh disabled.')
    end
  end

  def self.authorized_actor(id)
    actor = User.find_by(id: id, active: true, tenant_id: Current.tenant_id)
    actor if actor&.can_manage_accounts? && actor.can?('timesheets.write')
  end

  def self.verify!(snapshot)
    raise SquareTimecardImport::Error, 'Square timesheet schedule changed. Existing hours retained.' unless snapshot['enabled'] == true && configuration == snapshot && authorized_actor(snapshot['actor_id'])
  end

  def self.call
    snapshot = configuration
    return unless snapshot['enabled'] == true

    SyncObservability.observe('square', 'timecards') do
      verify!(snapshot)
      actor = authorized_actor(snapshot['actor_id'])
      SquareTimecardImport.new(actor: actor, sync_configuration: snapshot).call(apply: true)
    end
  end
end
