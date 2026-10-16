# frozen_string_literal: true

require 'bigdecimal'
require 'csv'

# Two observations of shared stock, never a sum or an inventory adjustment.
class StockComparison
  attr_reader :shopify_snapshots, :ctrax_snapshots, :shopify, :ctrax, :query, :filter, :findings

  def initialize(shopify_location_id: nil, ctrax_location_id: nil, query: nil, filter: nil, at: Time.current)
    @at = at
    @query = query.to_s.strip[0, 255]
    @filter = %w[attention unmatched candidates historical findings].include?(filter) ? filter : 'all'
    @shopify_snapshots = ShopifyStockSnapshot.includes(:location).order(:location_id).select { |s| s.location&.active }
    @ctrax_snapshots = CtraxStockSnapshot.includes(:location).order(:location_id).select { |s| s.location&.active }
    @shopify = selected(@shopify_snapshots, shopify_location_id, prefer_stock: true)
    @ctrax = selected(@ctrax_snapshots, ctrax_location_id)
  end

  def rows
    @rows ||= build_rows.select do |row|
      (@query.blank? || [row[:label], row[:ctrax_label], row[:sku], row[:ctrax_sku], row[:shopify_barcode], row[:ctrax_barcode], row[:shopify_id], row[:ctrax_id], row[:finding_notes].map { |n| n[:text] }.join(' ')].compact.join(' ').downcase.include?(@query.downcase)) &&
        (@filter != 'attention' || row[:issues].any? || row[:difference]&.nonzero?) &&
        (@filter != 'unmatched' || !row[:paired]) &&
        (@filter != 'candidates' || row[:identity] == 'Name/package candidate' || row[:identity].start_with?('Investigated ')) &&
        (@filter != 'findings' || row[:finding_notes].any?) &&
        (@filter != 'historical' || row[:historical].any?)
    end.sort_by { |row| [row[:issues].any? ? 0 : 1, row[:label].downcase, row[:shopify_id].to_s, row[:ctrax_id].to_s] }
  end

  def summary
    all = build_rows
    { rows: all.size, paired: all.count { |r| r[:paired] }, unknown: all.count { |r| r[:issues].include?('Unknown stock') },
      negative: all.count { |r| r[:issues].include?('Negative stock') }, unpaired: all.count { |r| !r[:paired] },
      name_candidates: all.count { |r| r[:identity] == 'Name/package candidate' }, historical: all.count { |r| r[:historical].any? },
      investigated_candidates: all.count { |r| r[:identity].start_with?('Investigated ') }, findings: all.count { |r| r[:finding_notes].any? } }
  end

  def stale?(snapshot)
    snapshot && snapshot.captured_at < @at - 1.hour
  end

  def catalog_read_at
    ShopifyProduct.maximum(:catalog_read_at)
  end

  def historical_catalog_count
    ShopifyVariant.where(catalog_present: false).count
  end

  def csv
    CSV.generate do |csv|
      csv << ['Item', 'SKU', 'Shopify variant ID', 'C-Trax variant ID', 'Identity', 'Shopify location', 'C-Trax store',
        'Shopify on hand', 'Shopify available', 'Shopify committed', 'C-Trax stock', 'C-Trax minus Shopify on hand',
        'Issues', 'Shopify read time', 'C-Trax read time', 'C-Trax item', 'C-Trax SKU', 'Shopify barcode', 'C-Trax barcode', 'Match evidence', 'Historical Shopify candidates', 'Investigation date', 'Investigation findings', 'Investigation current']
      rows.each do |row|
        values = [row[:label], row[:sku], row[:shopify_id], row[:ctrax_id], row[:identity], shopify&.location&.name, ctrax&.location&.name,
          row[:on_hand], row[:available], row[:committed], row[:ctrax_quantity], row[:difference], row[:issues].join('; '),
          shopify&.captured_at&.iso8601, ctrax&.captured_at&.iso8601, row[:ctrax_label], row[:ctrax_sku],
          row[:shopify_barcode], row[:ctrax_barcode], row[:evidence].join('; '), row[:historical].map { |v| "#{v[:id]} (#{v[:status] || 'unknown status'}; present=#{v[:present]})" }.join('; '),
          findings&.reviewed_at&.iso8601, row[:finding_notes].map { |n| n[:text] }.join('; '), row[:finding_notes].any? ? row[:finding_notes].all? { |n| n[:current] } : nil]
        csv << values.map do |value|
          if value.is_a?(BigDecimal)
            value.to_s('F').delete_suffix('.0')
          elsif value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/)
            "'#{value}"
          else
            value
          end
        end
      end
    end
  end

  private

  def selected(snapshots, id, prefer_stock: false)
    return snapshots.find { |s| s.location_id == id } || raise(ActiveRecord::RecordNotFound) if id.present?

    choices = prefer_stock ? snapshots.select { |s| s.records.any? } : snapshots
    choices.one? ? choices.first : nil
  end

  def build_rows
    return @all_rows if @all_rows

    catalog = ShopifyVariant.current_catalog.includes(:product).to_a
    variants = catalog.select(&:tracked)
    stocks = shopify ? shopify.records.index_by { |r| r['id'] } : {}
    records = ctrax ? ctrax.records : []
    historical = ShopifyVariant.where.not(id: catalog.map(&:id)).includes(:product).to_a
    @findings = StockIdentityFindings.new(shopify: shopify, ctrax: ctrax, catalog: catalog, records: records, at: @at)
    matcher = StockIdentityMatcher.new(catalog: catalog, records: records, historical: historical, findings: findings)
    used = []
    result = variants.map do |variant|
      match = matcher.matches.fetch(variant.id)
      record = match.record
      used << record.fetch('id') if record
      stock = stocks[variant.id] if shopify && variant.catalog_read_at == shopify.captured_at
      build_row(variant, stock, record, match.identity, evidence: match.evidence, match_issues: match.issues,
        name_candidate: match.priority == 2)
    end
    result.concat(records.reject { |r| used.include?(r.fetch('id')) }.map do |record|
      diagnostic = matcher.unmatched(record)
      build_row(nil, nil, record, diagnostic[:identity], evidence: diagnostic[:evidence], historical: diagnostic[:historical])
    end)
    @all_rows = result
  end

  def build_row(variant, stock, record, identity, evidence: [], match_issues: [], historical: [], name_candidate: false)
    issues = match_issues.dup
    finding_notes = findings.notes_for(variant, record)
    issues << 'Saved investigation needs refresh; source identity changed or review expired' if finding_notes.any? { |note| !note[:current] }
    issues << 'Source details flagged in investigation' if finding_notes.any? { |note| note[:severity] == 'warning' }
    on_hand = stock && stock['on_hand']
    available = stock && stock['available']
    committed = stock && stock['committed']
    quantity = record && record['quantity'] && BigDecimal(record['quantity'].to_s)
    paired = variant && record
    issues << 'Unknown stock' if (variant && on_hand.nil?) || (record && quantity.nil?)
    issues << 'Negative stock' if [on_hand, available, quantity].compact.any?(&:negative?)
    issues << 'Stock tracking off/unverified' if record && !record['manage_stock']
    issues << 'Fractional stock; unit mapping required' if quantity && !quantity.frac.zero?
    issues << 'Stale Shopify read' if variant && stale?(shopify)
    issues << 'Stale C-Trax read' if record && stale?(ctrax)
    issues << identity unless paired
    comparable = !name_candidate && issues.none? { |issue| issue.include?('quantity difference withheld') } && paired && on_hand && quantity && record['manage_stock'] && quantity.frac.zero? && !stale?(shopify) && !stale?(ctrax)
    { label: variant ? [variant.product&.title, variant.title].compact.join(' · ') : record['name'].presence || "C-Trax #{record['id']}",
      sku: variant&.sku.presence || record&.dig('sku'), shopify_id: variant&.id, ctrax_id: record&.dig('id'),
      on_hand: on_hand, available: available, committed: committed, ctrax_quantity: quantity,
      difference: comparable ? quantity - on_hand : nil, identity: identity, paired: !!paired, issues: issues,
      listed: record && record.fetch('listed', true), ctrax_label: record&.dig('name'), ctrax_sku: record&.dig('sku'),
      shopify_barcode: variant&.barcode, ctrax_barcode: record&.dig('barcode'), evidence: evidence, historical: historical, finding_notes: finding_notes }
  end
end
