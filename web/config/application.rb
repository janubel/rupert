# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'
require_relative 'shopify_api_version'

# Load the repo-root .env (credentials for the sync engine live there). Skipped
# in the test environment so real credentials on the dev box never leak into
# tests/CI logs — tests provide their own values.
require 'dotenv'
Dotenv.load(File.expand_path('../../.env', __dir__)) unless Rails.env.test?
if ENV['HOST'].present? && !ENV['HOST'].match?(%r{\Ahttps?://})
  ENV['HOST'] = "https://#{ENV['HOST']}"
end

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ShopifyAppTemplateRuby
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults(8.1)

    config.assets.prefix = '/api/assets'

    # ERP modules live in app/modules/<name>. The directory is the autoload
    # root, so app/modules/core/order.rb -> Core::Order. New modules are
    # picked up automatically.
    config.autoload_paths << Rails.root.join('app/modules')

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    if ShopifyAPI::Context.embedded?
      config.action_dispatch.default_headers = config.action_dispatch.default_headers.merge({
                                                                                              'Access-Control-Allow-Origin' => '*',
                                                                                              'Access-Control-Allow-Headers' => 'Authorization',
                                                                                              'Access-Control-Expose-Headers' => 'X-Shopify-API-Request-Failure-Reauthorize-Url'
                                                                                            })
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Store timestamps in UTC and display them in the store's local time.
    config.time_zone = 'Eastern Time (US & Canada)'
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
