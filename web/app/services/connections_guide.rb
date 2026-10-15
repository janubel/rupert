# frozen_string_literal: true

# Human-facing guide to every service Rupert talks to and the keys it needs.
# Powers the Connections page so a non-technical owner can see, at a glance:
#   - whether each service is configured (all keys set / partial / missing)
#   - where to find each key in the provider's admin
#   - how (and when) the key needs renewing
class ConnectionsGuide
  Service = Struct.new(:key, :name, :description, :keys, :find_url, :find_hint, :renewal_note, keyword_init: true)

  SERVICES = [
    Service.new(
      key: 'shopify',
      name: 'Shopify',
      description: 'Product catalog and online orders.',
      keys: %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN SHOPIFY_LOCATION_ID],
      find_url: 'https://admin.shopify.com/',
      find_hint: 'Store admin → Settings → Apps and sales channels, or your Partner dashboard → Apps. SHOPIFY_LOCATION_ID is optional — it pins which location counts as your primary selling location; leave it blank and the sync picks the first active one.',
      renewal_note: 'Secrets can be rotated any time. If a sync reports an invalid token, re-install the app or regenerate the client secret — nothing else changes.'
    ),
    Service.new(
      key: 'square',
      name: 'Square',
      description: 'In-store (POS) sales and inventory.',
      keys: %w[SQUARE_APPLICATION_ID SQUARE_ACCESS_TOKEN SQUARE_ENVIRONMENT SQUARE_LOCATION_ID],
      find_url: 'https://developer.squareup.com/apps',
      find_hint: 'Square Developer Dashboard → your app → OAuth. The access token is under Authorization.',
      renewal_note: 'This connector uses a manually supplied access token. It does not implement OAuth login or automatic token refresh. If the token expires or is revoked, replace it through the Developer Dashboard.'
    ),
    Service.new(
      key: 'google_drive',
      name: 'Google Drive backup',
      description: 'Automatic database snapshots to a private Drive folder.',
      keys: %w[GOOGLE_DRIVE_CLIENT_ID GOOGLE_DRIVE_CLIENT_SECRET GOOGLE_DRIVE_REFRESH_TOKEN
               GOOGLE_DRIVE_FOLDER_ID],
      find_url: 'https://console.cloud.google.com/apis/credentials',
      find_hint: 'Google Cloud Console → APIs & Services → Credentials → your OAuth 2.0 Client ID.',
      renewal_note: 'The refresh token can lapse after about 6 months of inactivity. If backups stop, run the Connect flow on the Settings page again — no other setup is needed.'
    ),
    Service.new(
      key: 'buzz',
      name: 'Buzz agent',
      description: "Rupert's Nostr identity for channel announcements.",
      keys: %w[BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_PRIVATE_KEY BUZZ_ANNOUNCEMENTS_CHANNEL],
      find_url: nil,
      find_hint: 'Relay URL and channel ids come from your Buzz workspace. The private key is generated inside Rupert (Settings → Buzz agent).',
      renewal_note: 'Generate a fresh agent keypair any time from the Settings page. Republish the profile so the relay recognizes the new npub, then re-add it to the channel.'
    ),
    Service.new(
      key: 'authorize_net',
      name: 'Authorize.net',
      description: 'Card payments on warehouse-sale vendor links.',
      keys: %w[AUTHORIZE_NET_LOGIN_ID AUTHORIZE_NET_TRANSACTION_KEY AUTHORIZE_NET_CLIENT_KEY
               AUTHORIZE_NET_SANDBOX],
      find_url: 'https://account.authorize.net/',
      find_hint: 'Merchant Interface → Account → API Credentials & Keys. The client key is what the checkout page embeds for Accept.js.',
      renewal_note: "Rotate the transaction key any time from the Merchant Interface. Keep AUTHORIZE_NET_SANDBOX=1 until you're ready to take real charges."
    ),
    Service.new(
      key: 'sync',
      name: 'Sync schedule',
      description: 'How often syncs run and how much history they pull. No secrets.',
      keys: %w[SYNC_MINUTES SYNC_HISTORY_DAYS FULFILLMENT_ALERT_HOURS],
      find_url: nil,
      find_hint: 'These are tuning knobs, not secrets — change them from the Settings page or .env import.',
      renewal_note: nil
    )
  ].freeze

  class << self
    def services
      SERVICES.map { |service| decorate(service) }
    end

    # Overall health: how many services are fully configured.
    def configured_count
      SERVICES.count { |service| status_for(service) == :configured }
    end

    private

    def decorate(service)
      key_rows = service.keys.map do |key|
        value = EnvStore.fetch(key, '')
        {
          key: key,
          set: value.present?,
          masked: value.present? ? EnvStore.mask(value) : nil,
          source: Setting.exists?(key: key, tenant_id: Current.tenant_id) ? 'database' : 'environment'
        }
      end
      status = status_for(service)
      {
        key: service.key,
        name: service.name,
        description: service.description,
        find_url: service.find_url,
        find_hint: service.find_hint,
        renewal_note: service.renewal_note,
        keys: key_rows,
        status: status,
        status_label: status_label(status)
      }
    end

    def status_for(service)
      set_count = service.keys.count { |key| EnvStore.fetch(key, '').present? }
      case set_count
      when service.keys.length then :configured
      when 0 then :missing
      else :partial
      end
    end

    def status_label(status)
      { configured: 'Configured', partial: 'Partially set up', missing: 'Not configured' }.fetch(status)
    end
  end
end
