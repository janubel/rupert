# frozen_string_literal: true

require Rails.root.join('app/middleware/build_version_header')
Rails.application.config.middleware.insert_before(0, BuildVersionHeader)
Rails.application.config.after_initialize { BuildInfo.current }
