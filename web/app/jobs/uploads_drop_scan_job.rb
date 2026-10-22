# frozen_string_literal: true

# Picks up files from the optional host drop directory. A no-op unless
# UPLOADS_DROP_ENABLED=1 and UPLOADS_DROP_DIR are set; see docs/ops/uploads-inbox.md.
class UploadsDropScanJob < ApplicationJob
  queue_as :default

  def perform
    return unless Uploads::DropScanner.enabled?

    report = Uploads::DropScanner.call
    return if report.disabled_reason

    logger.info("[uploads] event=drop_scan taken=#{report.taken} duplicates=#{report.duplicates} quarantined=#{report.quarantined} skipped=#{report.skipped}")
  rescue StandardError => e
    logger.error("#{self.class}: drop scan failed: #{e.class}")
  end
end
