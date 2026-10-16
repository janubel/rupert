# frozen_string_literal: true

# Verified connection methods. Merchant login never implies API or terminal access.
class PosProviderCatalog
  PROVIDERS = [
    { key: 'iris_reporting', name: 'NAB / IRIS merchant reporting', relationship: 'Processor deposits and reconciliation', mode: 'api',
      description: 'Read deposits, batches and transaction reports; import monthly Health Center summaries.',
      website: 'https://nabankco.iriscrm.com/merchant-portal', docs: 'https://nabankco.iriscrm.com/api',
      instructions: 'Use an API token issued for your IRIS tenant and authorized merchant IDs. Tokens inherit the issuing user’s permissions. A merchant portal password is not an API token. If API Settings is absent, NAB must enable appropriate reporting access or provide an approved integration user. Enter comma-separated merchant IDs to keep multiple accounts separate. Monthly CSV imports are available without API access.',
      credentials: %w[api_url api_token] },
    { key: 'authorize_net_reporting', name: 'Authorize.net reporting', relationship: 'Payment reconciliation', mode: 'api',
      description: 'Read transaction status, refunds, voids and settlement batches without processing payments.',
      website: 'https://account.authorize.net/', docs: 'https://developer.authorize.net/api/reference/features/transaction-reporting.html',
      instructions: 'Use a read-scope OAuth application where available. OAuth registration requires partner access and merchant owner/admin consent. Alternatively, API Login ID and Transaction Key can read reports but also permit payment processing: they are not read-only credentials. Never rotate a live checkout key for this setup. Enter the numeric Gateway ID from your merchant account as the merchant reference. C-Trax remains the retail inventory reference.',
      credentials: %w[api_login_id transaction_key] },
    { key: 'valmar', name: 'Valmar', relationship: 'Current processor described by the business', mode: 'vendor',
      description: 'Record the merchant account and actual gateway before choosing a payment adapter.',
      website: 'https://app.valmarpayments.com/', docs: 'https://vlmr.com/knowledge-base/',
      instructions: 'Open the Valmar portal and confirm your gateway, merchant approval and supported terminal. Valmar supports multiple gateway arrangements; a Valmar login alone does not identify an API.',
      credentials: [] },
    { key: 'pax', name: 'PAX terminal', relationship: 'Current terminal described by the business', mode: 'vendor',
      description: 'Prepare the terminal and processor details needed for the correct payment bridge.',
      website: 'https://www.pax.us/', docs: 'https://www.paxstore.us/developer',
      instructions: 'Confirm the terminal model, installed payment application and processor with Valmar. Obtain the approved SDK/bridge and test terminal from PAX or the processor. This screen does not send terminal commands.',
      credentials: [] },
    { key: 'ctrax', name: 'C-Trax', relationship: 'Retail inventory reference', mode: 'api',
      description: 'Read store stock from C-Trax for physical inventory counts.',
      website: 'https://www.c-trax.com/', docs: 'https://www.c-trax.com/dispensary-analytics/',
      instructions: 'Use a C-Trax user authorized to read your stores. Enter the HTTPS API origin from your portal configuration and that user’s login. This connector uses the Serv 2.0 portal API; vendor-supported partner access has not yet been established. TRX merchant Client ID, Password/Token and Algorithm belong to payment processing and do not authenticate inventory reads. Stock sync never changes C-Trax inventory or payment settings.',
      credentials: %w[api_url api_username api_password] },
    { key: 'swipesimple', name: 'SwipeSimple', relationship: 'Merchant sales reporting', mode: 'web',
      description: 'Pull fresh transaction and invoice exports from SwipeSimple Web on demand and every 30 minutes.',
      website: 'https://swipesimple.com/', docs: 'https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations',
      instructions: 'Authorize Rupert to sign in with your existing SwipeSimple website account and read full transaction and invoice exports. SwipeSimple does not publish a payments integration API; this uses its website export flow and may need repair when the website changes. Enter the numeric company ID from your dashboard URL. Exports use USD and America/New_York. Additional sign-in verification pauses automatic pulls until you restore access. No payments or account settings are changed.',
      credentials: %w[web_email web_password] },
    { key: 'korona', name: 'KORONA POS', relationship: 'Evaluation candidate', mode: 'api',
      description: 'Save dedicated API credentials and check read access to the account’s store structure.',
      website: 'https://www.koronacloud.com/', docs: 'https://manual.koronapos.com/how-can-i-integrate-with-korona-pos-api-apiv3-widget/',
      instructions: 'In KORONA Studio, create a dedicated API v3 user with the read permissions required for your account. Copy the exact API endpoint, account UUID, API login and API password from its API widget. Use a trial account for testing. Do not enter your everyday admin password or transient External Form credentials.',
      credentials: %w[api_url account_id api_username api_password] },
    { key: 'cova', name: 'Cova', relationship: 'Evaluation candidate', mode: 'api',
      description: 'Prepare approved integrator credentials and check access to the company’s locations.',
      website: 'https://api.covasoft.net/', docs: 'https://api.covasoft.net/GetStarted',
      instructions: 'Cova must approve the integration and supply its Onboarding Package: Company ID, client ID/secret and API username/password. These are integration credentials, not ordinary merchant sign-in. The check obtains a short-lived access token and reads locations; it does not retain the token or process payments.',
      credentials: %w[company_id client_id client_secret api_username api_password] },
    { key: 'shopify', name: 'Shopify', relationship: 'Existing website connector', mode: 'existing',
      description: 'Use Rupert’s existing tenant Shopify connection for catalog and online order imports.',
      website: 'https://admin.shopify.com/', docs: 'https://techmore.github.io/rupert/api.html',
      instructions: 'Manage the existing Shopify connection in Settings. The website’s Valmar processing arrangement is separate from Rupert’s catalog/order connection. Saving POS setup here does not install an app, sync or change payment settings.',
      credentials: [] },
    { key: 'square', name: 'Square', relationship: 'Previous provider; existing connector retained', mode: 'existing',
      description: 'Use the existing manually configured token connector only for an eligible account.',
      website: 'https://developer.squareup.com/apps', docs: 'https://developer.squareup.com/docs/access-tokens',
      instructions: 'Confirm account eligibility with Square before reconnecting. Rupert’s existing connector uses a manually supplied token; it does not implement OAuth account login or automatic token refresh. Manage those keys in Settings.',
      credentials: [] }
  ].freeze

  VALMAR_GATEWAY_CREDENTIALS = {
    'authorize_net' => %w[api_login_id transaction_key],
    'nmi' => %w[security_key]
  }.freeze

  VALMAR_GATEWAY_DETAILS = {
    'authorize_net' => {
      name: 'Authorize.net', docs: 'https://developer.authorize.net/api/reference/index.html',
      instructions: 'Use the API Login ID and transaction key issued for the selected sandbox or production merchant account. This check verifies API authentication only. It does not read transactions, enable checkout, send a payment or operate a terminal.'
    },
    'nmi' => {
      name: 'NMI', docs: 'https://docs.nmi.com/reference/query',
      instructions: 'Use the private API security key approved for the selected NMI merchant account. The check reads only the merchant profile through the Query API. A private key may permit other operations, so keep it secure. Use your own dedicated sandbox account; the shared NMI demo account does not support these queries.'
    }
  }.freeze

  def self.credential_keys(provider, gateway: nil)
    return VALMAR_GATEWAY_CREDENTIALS.fetch(gateway, []) if provider == 'valmar'

    find(provider)&.fetch(:credentials, []) || []
  end

  def self.check_kind(provider, gateway: nil)
    return gateway if provider == 'valmar' && VALMAR_GATEWAY_CREDENTIALS.key?(gateway)
    return provider if %w[korona cova ctrax].include?(provider)

    nil
  end

  def self.gateway_details(provider, gateway: nil)
    VALMAR_GATEWAY_DETAILS[gateway] if provider == 'valmar'
  end

  def self.all
    PROVIDERS
  end

  def self.find(key)
    PROVIDERS.find { |provider| provider[:key] == key.to_s }
  end
end
