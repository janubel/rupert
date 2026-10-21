# frozen_string_literal: true

# First in the stack, so retired hosts are redirected before host authorization
# (which is not in the test stack, so it cannot be the anchor).
require Rails.root.join('app/middleware/legacy_host_redirect')
Rails.application.config.middleware.insert_before(0, LegacyHostRedirect)
