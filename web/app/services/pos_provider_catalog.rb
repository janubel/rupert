# frozen_string_literal: true

# Verified connection methods. Merchant login never implies API or terminal access.
class PosProviderCatalog
  PROVIDERS = [
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
    { key: 'swipesimple', name: 'SwipeSimple', relationship: 'Processor-proposed replacement option', mode: 'csv',
      description: 'Import a transaction export through the existing SwipeSimple CSV importer.',
      website: 'https://swipesimple.com/', docs: 'https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations',
      instructions: 'Use the transaction CSV export and Rupert’s Sync import. SwipeSimple does not publish a payments integration API. Confirm the merchant account, terminal and tipping workflow with Valmar before switching.',
      credentials: [] },
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
