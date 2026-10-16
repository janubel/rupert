# frozen_string_literal: true

# Legacy per-source acquisition evidence, never an instrumented receipt or
# source-event coverage watermark. Combined runs always read Shopify, but may
# skip Square. Per-source watermarks advance only after that source imports.
class CatalogSyncHistory
  def self.watermark(source)
    value = Setting.find_by(key: "sync_watermark_#{source}", tenant_id: Current.tenant_id)&.value
    return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/)

    time = DateTime.iso8601(value).to_time
    time if time <= Time.current
  rescue ArgumentError
    nil
  end

  def self.legacy_success(source)
    sources = source == 'shopify' ? %w[shopify all] : [source]
    finished = SyncRun.where(source: sources, status: 'success').where('"finishedAt" <= ?', Time.current).maximum(:finishedAt)
    [finished, watermark(source)].compact.max
  end
end
