# frozen_string_literal: true

require Rails.root.join('app/middleware/immutable_asset_cache')

# Wraps the static file server so fingerprinted assets get a long cache lifetime.
Rails.application.config.middleware.insert_before(ActionDispatch::Static, ImmutableAssetCache)
