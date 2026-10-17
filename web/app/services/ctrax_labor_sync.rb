# frozen_string_literal: true

# Explicit per-workspace opt-in. The actor remains accountable on every run.
class CtraxLaborSync
  KEY = 'ctrax_labor_schedule'

  def self.configuration
    value = JSON.parse(Setting.find_by(tenant_id: Current.tenant_id, key: KEY)&.value || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  def self.enabled?
    configuration['enabled'] == true
  end

  def self.authorized_actor(id)
    actor = User.find_by(id: id, active: true)
    actor if actor&.can_manage_accounts? && actor.can?('timesheets.write') &&
      (actor.super_admin? || actor.tenant_id == Current.tenant_id)
  end

  def self.configure!(enabled:, actor: Current.user)
    raise Ctrax::LaborImport::Error.new('Choose whether automatic C-Trax reads are enabled.', reason: :invalid) unless [true, false].include?(enabled)

    Tenant.transaction do
      unless Tenant.where(id: Current.tenant_id, status: 'active').update_all('updated_at = updated_at') == 1
        raise Pundit::NotAuthorizedError
      end
      actor = authorized_actor(actor&.id)
      raise Pundit::NotAuthorizedError unless actor

      connection = PosConnection.find_by(provider: 'ctrax', vendor_approved: true)
      if enabled && !(connection&.credentials_saved? && Ctrax::Client.valid_credentials?(connection.credential_values))
        raise Ctrax::LaborImport::Error.new('Configure approved C-Trax read access first.', reason: :invalid)
      end
      Setting.find_or_create_for(KEY, Current.tenant_id) do |setting|
        setting.value = { enabled: enabled, actor_id: actor.id, version: SecureRandom.hex(24) }.to_json
      end
      ActivityLogger.log('ctrax_labor_schedule_updated', details: enabled ? 'Read-only punch refresh every 15 minutes enabled.' : 'Automatic punch refresh disabled.')
    end
  end

  def self.verify!(snapshot)
    unless snapshot['enabled'] == true && configuration == snapshot && authorized_actor(snapshot['actor_id'])
      raise Ctrax::LaborImport::Error.new('C-Trax timesheet schedule or authorization changed. Existing history retained.', reason: :changed)
    end
  end

  def self.call
    snapshot = configuration
    return unless snapshot['enabled'] == true

    SyncObservability.observe('ctrax', 'timecards') do
      verify!(snapshot)
      Ctrax::LaborImport.call(actor: authorized_actor(snapshot['actor_id']), sync_configuration: snapshot)
    end
  end
end
