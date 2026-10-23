# frozen_string_literal: true

# Wraps the static file server so fingerprinted assets get a long cache lifetime.
Rails.application.config.middleware.insert_before(ActionDispatch::Static, ImmutableAssetCache)
