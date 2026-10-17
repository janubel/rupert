# frozen_string_literal: true

# Also identifies health, API, download and error responses without a layout.
class BuildVersionHeader
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    [status, headers.merge('x-rupert-build' => BuildInfo.current.revision), body]
  end
end
