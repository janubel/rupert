# frozen_string_literal: true

module ConnectionsHelper
  def connection_source_setup_path(source)
    provider = ConnectionControlCenter::SOURCE_SETUP[source[:key]]
    return pos_connection_path(provider) if provider
    return settings_path(anchor: 'drive') if source[:key] == 'google_backup'

    edit_connection_path(source[:key])
  end

  def connection_service_setup_path(service)
    return pos_connection_path(service[:key]) if service[:kind] == 'provider'
    return settings_path(anchor: 'drive') if service[:key] == 'google_drive'
    # Services whose keys have no managed form (Apple Pay's PEM certificate and
    # key) are set from the .env import; linking to the edit form would 404.
    return settings_path(anchor: 'env') unless ConnectionCredentials::FIELDS.key?(service[:key])

    edit_connection_path(service[:key])
  end

  def connection_source_can_sync?(source)
    return false unless Current.user.can?('sync.write') && source[:ready]
    return false if source[:badge] == 'Syncing'
    return false if source[:key] == 'ctrax' && !Current.user.can?('inventory.write')
    return false if source[:key] == 'authorize_net' && source[:mode] == 'api' && !Current.user.can?('settings.write')

    %w[shopify ctrax swipesimple authorize_net].include?(source[:key])
  end
end
