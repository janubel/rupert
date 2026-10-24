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
      renewal_note: 'Coordinate client changes with every consumer of this app. Verify a fresh read after updating Rupert. A delayed job alone is not a reason to replace credentials.'
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
      key: 'google_sign_in',
      name: 'Google sign-in',
      description: 'Team sign-in for the allowed workspace email domains.',
      keys: %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET],
      find_url: 'https://console.cloud.google.com/apis/credentials',
      find_hint: 'Use the OAuth client configured for Rupert sign-in. Manage allowed email domains separately in Settings.',
      renewal_note: 'Coordinate client changes with the operator. Google sign-in and Google Drive backups use separate settings.'
    ),
    Service.new(
      key: 'google_drive',
      name: 'Google Drive backup',
      description: 'Platform-only snapshots of the entire shared instance database to an approved private Drive folder.',
      keys: %w[GOOGLE_DRIVE_CLIENT_ID GOOGLE_DRIVE_CLIENT_SECRET GOOGLE_DRIVE_REFRESH_TOKEN
               GOOGLE_DRIVE_FOLDER_ID],
      find_url: 'https://console.cloud.google.com/apis/credentials',
      find_hint: 'Google Cloud Console → APIs & Services → Credentials → your OAuth 2.0 Client ID.',
      renewal_note: 'If authorization fails, the platform operator should review backup status and restore the approved connection through Settings. Verify a new backup and a separate restore drill.'
    ),
    Service.new(
      key: 'authorize_net',
      name: 'Authorize.net checkout',
      description: 'Card payments on warehouse-sale vendor links.',
      keys: %w[AUTHORIZE_NET_LOGIN_ID AUTHORIZE_NET_TRANSACTION_KEY AUTHORIZE_NET_CLIENT_KEY
               AUTHORIZE_NET_SANDBOX],
      find_url: 'https://account.authorize.net/',
      find_hint: 'Merchant Interface → Account → API Credentials & Keys. The client key is what the checkout page embeds for Accept.js.',
      renewal_note: 'Do not generate a new Transaction Key for reporting setup: Shopify and other checkouts may share ' \
                    'the existing key. Rotation expires the old key immediately or after 24 hours and requires ' \
                    'coordinated updates to every consumer. Use the existing key securely or approved OAuth read access ' \
                    'for reporting.'
    ),
    Service.new(
      key: 'apple_pay',
      name: 'Apple Pay',
      description: 'Apple Pay button on warehouse checkout. Payments still run through Authorize.net.',
      keys: %w[APPLE_PAY_MERCHANT_ID APPLE_PAY_DISPLAY_NAME APPLE_PAY_IDENTITY_CERT APPLE_PAY_IDENTITY_KEY APPLE_PAY_DOMAIN_ASSOCIATION],
      find_url: 'https://developer.apple.com/account/resources/identifiers/list/merchant',
      find_hint: 'Apple Developer → Identifiers → Merchant IDs. Create a Merchant ID, add your checkout domain, paste the downloaded domain-association file’s contents as APPLE_PAY_DOMAIN_ASSOCIATION (Rupert serves it at /.well-known/apple-developer-merchantid-domain-association; then press Verify in Apple’s portal), and create a Merchant Identity Certificate (paste its PEM certificate and private key). Separately, in the Authorize.net Merchant Interface (Account → Digital Payment Solutions → Apple Pay) generate the Payment Processing certificate request and upload Apple\'s signed certificate back.',
      renewal_note: 'Apple certificates expire after about 25 months. Renew both the Merchant Identity and Payment Processing certificates before then or the button stops working.'
    ),
    Service.new(
      key: 'google_pay',
      name: 'Google Pay',
      description: 'Google Pay button on warehouse checkout. Payments still run through Authorize.net.',
      keys: %w[GOOGLE_PAY_MERCHANT_ID GOOGLE_PAY_MERCHANT_NAME],
      find_url: 'https://pay.google.com/business/console',
      find_hint: 'Google Pay & Wallet Console → your business profile → Merchant ID. Test mode (Authorize.net sandbox) needs no merchant ID; production needs Google to approve a screenshot of the checkout. No Authorize.net setup is needed: Rupert tells Google to use gateway authorizenet with your API Login ID.',
      renewal_note: nil
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
      visible_services.map { |service| decorate(service) }
    end

    # Overall health: how many services are fully configured.
    def configured_count
      visible_services.count { |service| status_for(service) == :configured }
    end

    private

    def visible_services
      platform_admin = User.find_by(id: Current.user&.id, active: true, role: 'super_admin')
      platform_admin ? SERVICES : SERVICES.reject { |service| service.key == 'google_drive' }
    end

    def decorate(service)
      key_rows = service.keys.map do |key|
        value = EnvStore.effective(key)
        {
          key: key,
          set: value.present?,
          masked: value.present? ? EnvStore.mask(value) : nil,
          source: Setting.exists?(key: key, tenant_id: EnvStore::PLATFORM_KEYS.include?(key) ? nil : Current.tenant_id) ? 'database' : 'environment'
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
      set_count = service.keys.count { |key| EnvStore.effective(key).present? }
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
