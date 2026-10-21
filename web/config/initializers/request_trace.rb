# frozen_string_literal: true

# In-memory trace of each signed-in session's recent requests for the in-app
# bug reporter (ladybug). See app/middleware/request_trace.rb.
require Rails.root.join('app/middleware/request_trace')
Rails.application.config.middleware.insert_before(Rails::Rack::Logger, RequestTrace::Middleware)
Rails.application.config.after_initialize { RequestTrace.install! }
