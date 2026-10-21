# frozen_string_literal: true

require 'csv'

# Lines each SwipeSimple item up with the same item in the other systems.
# Shopify is the hub: a SwipeSimple item is matched to a current Shopify
# variant by StockIdentityMatcher (source ID, then exact SKU/barcode, then exact
# product words + package as a candidate for review). Square names come from
# the Shopify↔Square SKU link; C-Trax names from matching each C-Trax store
# snapshot to the same Shopify variant. Nothing is saved or written anywhere.
class SwipesimpleItemMatch
  Row = Struct.new(:record, :status, :identity, :evidence, :issues, :shopify_id, :shopify_name, :shopify_sku,
    :square_name, :ctrax_name, :name_status, :suggested_name, keyword_init: true) do
    def swipesimple_name = record['name']
    def quantity = record['quantity']
    def matched? = !shopify_id.nil?
  end

  STATUSES = ['Matched', 'Review name match', 'Not matched'].freeze

  def initialize(snapshot)
    @snapshot = snapshot
  end

  def rows
    @rows ||= begin
      by_record = matcher.matches.each_with_object({}) do |(variant_id, match), found|
        found[match.record.fetch('id')] = [variant_id, match] if match.record
      end
      @snapshot.records.map do |record|
        variant_id, match = by_record[record['id']]
        match ? matched_row(record, catalog_by_id.fetch(variant_id), match) : unmatched_row(record)
      end.sort_by { |row| [STATUSES.index(row.status), row.swipesimple_name.to_s.downcase] }
    end
  end

  def summary
    { items: rows.size, matched: rows.count { |r| r.status == 'Matched' }, review: rows.count { |r| r.status == 'Review name match' },
      unmatched: rows.count { |r| r.status == 'Not matched' }, names_differ: rows.count { |r| r.name_status == 'Different name' },
      unknown_stock: rows.count { |r| r.quantity.nil? } }
  end

  HEADERS = ['SwipeSimple item', 'SwipeSimple SKU', 'SwipeSimple barcode', 'SwipeSimple category', 'SwipeSimple price', 'SwipeSimple stock',
             'Match', 'How matched', 'Shopify item', 'Shopify SKU', 'Square item', 'C-Trax item', 'Name', 'Suggested SwipeSimple name', 'Notes'].freeze

  def csv
    CSV.generate do |csv|
      csv << ['SwipeSimple items', @snapshot.merchant_account, "Imported #{@snapshot.captured_at.iso8601}"]
      csv << HEADERS
      rows.each do |row|
        r = row.record
        csv << [row.swipesimple_name, r['sku'], r['barcode'], r['category'], r['price'], r['quantity'] || 'Unknown', row.status, row.identity,
                row.shopify_name, row.shopify_sku, row.square_name, row.ctrax_name, row.name_status, row.suggested_name,
                (row.evidence + row.issues).join('; ')].map { |cell| safe(cell) }
      end
    end
  end

  def self.comparable(name)
    name.to_s.unicode_normalize(:nfkc).downcase.gsub(/\bdefault title\b/, ' ').gsub(/[^[:alnum:]]+/, ' ').squish
  end

  private

  def catalog = @catalog ||= ShopifyVariant.current_catalog.includes(:product).to_a
  def catalog_by_id = @catalog_by_id ||= catalog.index_by(&:id)

  def matcher
    @matcher ||= StockIdentityMatcher.new(catalog: catalog, records: @snapshot.records,
      historical: ShopifyVariant.where.not(id: catalog.map(&:id)).includes(:product).to_a)
  end

  def matched_row(record, variant, match)
    shopify_name = shopify_label(variant)
    same = self.class.comparable(record['name']) == self.class.comparable(shopify_name)
    Row.new(record: record, status: match.priority == 2 ? 'Review name match' : 'Matched', identity: match.identity,
      evidence: match.evidence, issues: match.issues, shopify_id: variant.id, shopify_name: shopify_name, shopify_sku: variant.sku,
      square_name: square_names[variant.id], ctrax_name: ctrax_names[variant.id],
      name_status: same ? 'Same name' : 'Different name', suggested_name: same ? nil : shopify_name)
  end

  def unmatched_row(record)
    diagnostic = matcher.unmatched(record)
    Row.new(record: record, status: 'Not matched', identity: diagnostic[:identity].to_s.gsub('C-Trax', 'SwipeSimple'),
      evidence: Array(diagnostic[:evidence]), issues: [], name_status: 'No match')
  end

  def shopify_label(variant)
    title = variant.title.to_s
    [variant.product&.title, (title unless title.casecmp?('Default Title') || title.blank?)].compact.join(' ')
  end

  # Shopify variant ID → "Square item · variation" through the SKU link.
  def square_names
    @square_names ||= SkuLink.where(shopifyVariantId: catalog.map(&:id)).where.not(squareVariationId: nil)
      .includes(square_variation: :item).each_with_object({}) do |link, names|
        variation = link.square_variation
        next unless variation

        label = [variation.item&.name, (variation.name unless variation.name.to_s.casecmp?('Regular'))].compact.join(' · ')
        names[link.shopifyVariantId] = label
      end
  end

  # Shopify variant ID → C-Trax item name(s) from each active store snapshot.
  def ctrax_names
    @ctrax_names ||= CtraxStockSnapshot.includes(:location).select { |s| s.location&.active && s.records.any? }
      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |snapshot, names|
        StockIdentityMatcher.new(catalog: catalog, records: snapshot.records).matches.each do |variant_id, match|
          names[variant_id] << match.record['name'] if match.record && match.priority < 2
        end
      end.transform_values { |list| list.uniq.join(' / ') }
  end

  def safe(value)
    value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
  end
end
