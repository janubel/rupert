# frozen_string_literal: true

# Local, read-only operator work queue. Exact source item/location identities
# remain independent. Limits bound database results and are disclosed in the UI.
class InventoryExceptions
  SOURCES = %w[shopify square].freeze
  SECTION_LABELS = { stock: 'Stock data', holds: 'Local hold shortages', identity: 'Catalog identity',
    counts: 'Pending counts', bulk: 'Depleted bulk lots', orders: 'Incomplete source orders' }.freeze
  SEVERITIES = { critical: 0, warning: 1, notice: 2 }.freeze
  MEMBER_LIMIT = 5

  attr_reader :source, :location_id, :stale_hours, :limit, :at, :per_page, :section

  def initialize(source: nil, location_id: nil, stale_hours: 1, limit: 50, at: Time.current, page: 1, per_page: 50, section: nil)
    @tenant_id = Current.tenant_id
    raise ActiveRecord::RecordNotFound unless @tenant_id.present?

    @source = source.to_s.strip.presence
    @location_id = location_id.to_s.strip.presence
    @stale_hours = integer_filter(stale_hours, 1..168)
    @limit = integer_filter(limit, 1..100)
    @requested_page = integer_filter(page, 1..1000)
    @per_page = integer_filter(per_page, 1..100)
    @section = section.to_s.presence
    @at = at
    raise ArgumentError if @source && !SOURCES.include?(@source)
    raise ArgumentError if @location_id && @location_id.length > 255
    raise ArgumentError if @section && !SECTION_LABELS.key?(@section.to_sym)
  end

  def sections
    require_tenant!
    @sections ||= [stock_section, hold_section, identity_section, count_section, bulk_section, order_section]
  end

  def rows
    require_tenant!
    @rows ||= sections.flat_map { |group| group[:rows] }
                      .select { |row| !section || row[:section].to_s == section }
                      .sort_by { |row| [SEVERITIES.fetch(row[:severity]), row[:kind], row[:source].to_s, row[:item_id].to_s, row[:location_id].to_s] }
  end

  def summary
    { shown: rows.length, limited: sections.any? { |group| group[:limited] } }
  end

  def total_pages
    [(rows.length.to_f / per_page).ceil, 1].max
  end

  def page
    [@requested_page, total_pages].min
  end

  def page_rows
    rows.slice((page - 1) * per_page, per_page) || []
  end

  private

  def require_tenant!
    raise ActiveRecord::RecordNotFound unless Current.tenant_id == @tenant_id
  end

  def integer_filter(value, range)
    text = value.to_s
    raise ArgumentError unless text.match?(/\A\d+\z/) && range.cover?(text.to_i)

    text.to_i
  end

  def section_result(key, rows, checks, note)
    rows.each { |row| row[:section] = key }
    { key: key, label: SECTION_LABELS.fetch(key), rows: rows, checks: checks,
      limited: checks.any? { |check| check[:limited] || check[:sample_limited] }, scope_note: note }
  end

  def bounded(scope, label, checks)
    records = scope.limit(limit + 1).to_a
    checks << { label: label, returned: [records.length, limit].min, limited: records.length > limit }
    records.first(limit)
  end

  def quoted_tenant
    ApplicationRecord.connection.quote(@tenant_id)
  end

  def level_scope
    scope = InventoryLevel.all
    scope = scope.where(source: source) if source
    scope = scope.where(locationId: location_id) if location_id
    scope
  end

  def identity_joins(scope)
    scope.joins(<<~SQL.squish)
      LEFT JOIN "Location" exception_location ON exception_location.id = "InventoryLevel"."locationId" AND exception_location.tenant_id = #{quoted_tenant}
      LEFT JOIN "ShopifyVariant" exception_shopify ON exception_shopify.id = "InventoryLevel"."shopifyVariantId" AND exception_shopify.tenant_id = #{quoted_tenant}
      LEFT JOIN "SquareVariation" exception_square ON exception_square.id = "InventoryLevel"."squareVariationId" AND exception_square.tenant_id = #{quoted_tenant}
    SQL
  end

  def invalid_pool_sql
    <<~SQL.squish
      "InventoryLevel".source NOT IN ('shopify', 'square') OR exception_location.id IS NULL OR exception_location.source <> "InventoryLevel".source OR
      ("InventoryLevel".source = 'shopify' AND (exception_shopify.id IS NULL OR "InventoryLevel"."squareVariationId" IS NOT NULL)) OR
      ("InventoryLevel".source = 'square' AND (exception_square.id IS NULL OR "InventoryLevel"."shopifyVariantId" IS NOT NULL))
    SQL
  end

  def stock_section
    checks = []
    scope = identity_joins(level_scope).where(<<~SQL.squish, at - stale_hours.hours)
      (#{invalid_pool_sql}) OR "InventoryLevel".quantity IS NULL OR "InventoryLevel".available IS NULL OR
      "InventoryLevel".quantity < 0 OR "InventoryLevel".available < 0 OR "InventoryLevel"."updatedAt" < ?
    SQL
    levels = bounded(scope.order(Arel.sql('CASE WHEN "InventoryLevel".quantity < 0 OR "InventoryLevel".available < 0 THEN 0 ELSE 1 END'), :updatedAt, :id),
      'Stock pools matching invalid, negative, unknown or stale data', checks)
    preload = ActiveRecord::Associations::Preloader.new(records: levels, associations: %i[location shopify_variant square_variation])
    preload.call
    rows = levels.flat_map do |level|
      issues = []
      issues << ['Invalid pool identity', :critical, 'Location/source/item identity is absent, inconsistent or unavailable in this store. Do not allocate or deduce stock from this record.'] unless valid_level?(level)
      issues << ['Negative mirrored stock', :critical, 'A mirrored on-hand or available value is negative. Verify the exact source item and location with a physical count.'] if [level.quantity, level.available].compact.any?(&:negative?)
      issues << ['Unknown mirrored stock', :warning, 'On-hand or available is missing. Availability cannot be confirmed; missing data is not zero stock.'] if level.quantity.nil? || level.available.nil?
      issues << ['Stale stock snapshot', :warning, "This pool was last updated before the selected #{stale_hours}-hour threshold. An import timestamp does not guarantee current physical stock."] if level.updatedAt < at - stale_hours.hours
      issues.map do |kind, severity, detail|
        { kind: kind, severity: severity, source: level.source, item_id: item_id(level), location_id: level.locationId,
          location_name: level.location&.name, label: level_label(level), detail: detail,
          quantity: level.quantity, available: level.available, observed_at: level.updatedAt, observed_label: 'Mirror updated',
          review_type: level.source == 'shopify' && level.shopify_variant ? :variant : :inventory,
          review_id: level.shopify_variant&.id }
      end
    end
    section_result(:stock, rows, checks, 'Native stock pools matching the source/location filter. Each source item at each location is checked independently; different channel quantities are not drift.')
  end

  def valid_level?(level)
    location = level.location
    item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
    opposite = level.source == 'shopify' ? level.squareVariationId : level.shopifyVariantId
    SOURCES.include?(level.source) && location&.tenant_id == @tenant_id && location.source == level.source &&
      item&.tenant_id == @tenant_id && opposite.nil?
  end

  def item_id(level)
    level.source == 'shopify' ? level.shopifyVariantId : level.squareVariationId
  end

  def level_label(level)
    item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
    name = level.source == 'shopify' ? item&.title : item&.name
    [item&.sku.presence, name.presence].compact.join(' · ').presence || 'Unresolved source item'
  end

  def hold_section
    checks = []
    active = StockReservation.active_at(at).group(:stock_reservation_pool_id)
                             .select('stock_reservation_pool_id, SUM(quantity) AS held_units')
    pools = StockReservationPool.joins("INNER JOIN (#{active.to_sql}) exception_holds ON exception_holds.stock_reservation_pool_id = stock_reservation_pools.id")
    pools = pools.where(source: source) if source
    pools = pools.where(location_id: location_id) if location_id
    pools = pools.joins(<<~SQL.squish)
      LEFT JOIN "InventoryLevel" exception_level ON exception_level.tenant_id = #{quoted_tenant} AND
      exception_level.source = stock_reservation_pools.source AND exception_level."locationId" = stock_reservation_pools.location_id AND
      ((stock_reservation_pools.source = 'shopify' AND exception_level."shopifyVariantId" = stock_reservation_pools.source_item_id AND exception_level."squareVariationId" IS NULL) OR
       (stock_reservation_pools.source = 'square' AND exception_level."squareVariationId" = stock_reservation_pools.source_item_id AND exception_level."shopifyVariantId" IS NULL))
    SQL
    pools = pools.joins(<<~SQL.squish)
      LEFT JOIN "Location" exception_hold_location ON exception_hold_location.id = stock_reservation_pools.location_id AND exception_hold_location.tenant_id = #{quoted_tenant}
      LEFT JOIN "ShopifyVariant" exception_hold_shopify ON exception_hold_shopify.id = stock_reservation_pools.source_item_id AND stock_reservation_pools.source = 'shopify' AND exception_hold_shopify.tenant_id = #{quoted_tenant}
      LEFT JOIN "SquareVariation" exception_hold_square ON exception_hold_square.id = stock_reservation_pools.source_item_id AND stock_reservation_pools.source = 'square' AND exception_hold_square.tenant_id = #{quoted_tenant}
    SQL
    invalid_identity = "stock_reservation_pools.source NOT IN ('shopify', 'square') OR exception_hold_location.id IS NULL OR exception_hold_location.source <> stock_reservation_pools.source OR (stock_reservation_pools.source = 'shopify' AND exception_hold_shopify.id IS NULL) OR (stock_reservation_pools.source = 'square' AND exception_hold_square.id IS NULL)"
    capacity = 'CASE WHEN exception_level.quantity < exception_level.available THEN exception_level.quantity ELSE exception_level.available END'
    pools = pools.where("(#{invalid_identity}) OR exception_level.id IS NULL OR exception_level.quantity IS NULL OR exception_level.available IS NULL OR exception_holds.held_units > (#{capacity})")
                 .select('stock_reservation_pools.*, exception_holds.held_units, exception_level.quantity AS mirror_quantity, exception_level.available AS mirror_available, exception_level."updatedAt" AS mirror_updated_at, exception_level.id AS mirror_id, exception_hold_location.id AS valid_location_id, exception_hold_location.source AS valid_location_source, exception_hold_shopify.id AS valid_shopify_id, exception_hold_square.id AS valid_square_id')
                 .order(Arel.sql('exception_holds.held_units DESC'), :id)
    rows = bounded(pools, 'Active hold pools with excess holds or unavailable mirrored capacity', checks).map do |pool|
      quantity = pool['mirror_quantity']
      available = pool['mirror_available']
      held = pool['held_units'].to_i
      identity_valid = pool['valid_location_id'] && pool['valid_location_source'] == pool.source &&
        (pool.source == 'shopify' ? pool['valid_shopify_id'] : pool['valid_square_id'])
      capacity_value = identity_valid && quantity && available ? [[quantity, available].min, 0].max : nil
      shortage = capacity_value ? [held - capacity_value, 0].max : nil
      { kind: shortage ? 'Local holds exceed capacity' : 'Held stock cannot be verified', severity: shortage ? :critical : :warning,
        source: pool.source, item_id: pool.source_item_id, location_id: pool.location_id,
        location_name: pool.location_name, label: pool.item_label, quantity: quantity, available: available, held: held, shortage: shortage,
        observed_at: InventoryLevel.type_for_attribute('updatedAt').deserialize(pool['mirror_updated_at']), observed_label: 'Mirror updated', review_type: :reservations,
        detail: shortage ? "#{held} locally held units exceed #{capacity_value} mirrored available units. Review holds and confirm source stock; channels can still sell it." : 'Active local holds exist, but their mirror or source/location identity is absent, inconsistent or has unknown capacity. Confirm stock and review holds; no shortage quantity can be inferred.' }
    end
    section_result(:holds, rows, checks, 'Active, unexpired local reservations in the selected source/location pools. Holds are advisory; they never change platform stock. Expired and released holds are excluded.')
  end

  def identity_section
    checks = []
    rows = []
    rows.concat(duplicate_rows(ShopifyVariant, :sku, 'shopify', 'Duplicate Shopify SKU', checks)) unless source == 'square'
    rows.concat(duplicate_rows(SquareVariation, :sku, 'square', 'Duplicate Square SKU', checks)) unless source == 'shopify'
    rows.concat(duplicate_rows(ShopifyVariant, :barcode, 'shopify', 'Duplicate Shopify barcode', checks)) unless source == 'square'
    rows.concat(link_rows(checks))
    rows.concat(shared_link_rows(checks))
    section_result(:identity, rows, checks, 'Catalog checks are source-wide and ignore the location filter. Links connect both platforms; matching text never merges physical stock. Missing links do not prove an item is carried on both platforms.')
  end

  def duplicate_rows(model, field, platform, kind, checks)
    table = model.quoted_table_name
    expression = field == :sku ? "LOWER(TRIM(#{table}.sku))" : "TRIM(#{table}.barcode)"
    base = model.where.not(field => [nil, '']).where("TRIM(#{table}.#{field}) <> ''")
    groups = base.group(Arel.sql(expression)).having('COUNT(*) > 1').order(Arel.sql(expression)).limit(limit + 1).count
    check = { label: kind, returned: [groups.length, limit].min, limited: groups.length > limit }
    checks << check
    selected = groups.to_a.first(limit)
    keys = selected.map(&:first)
    return [] if keys.empty?

    sample_cap = limit * MEMBER_LIMIT
    members = base.where("#{expression} IN (?)", keys).order(Arel.sql(expression), :id).limit(sample_cap + 1).pluck(:id, field)
    check[:sample_limited] = members.length > sample_cap
    by_key = members.first(sample_cap).group_by { |_, value| field == :sku ? value.strip.downcase : value.strip }
    selected.map do |value, count|
      ids = (by_key[value] || []).first(MEMBER_LIMIT).map(&:first)
      { kind: kind, severity: :critical, source: platform, label: value, item_id: ids.first,
        detail: "#{count} catalog records share this #{field == :sku ? 'case-insensitive, trimmed SKU' : 'trimmed barcode'}. Exact source identities: #{ids.join(', ').presence || 'not sampled'}#{count > ids.length ? ' (member sample only)' : ''}. Resolve identity before attributing sales or counting by this code.",
        review_type: :catalog }
    end
  end

  def link_rows(checks)
    scope = SkuLink.joins(<<~SQL.squish)
      LEFT JOIN "ShopifyVariant" exception_link_shopify ON exception_link_shopify.id = "SkuLink"."shopifyVariantId" AND exception_link_shopify.tenant_id = #{quoted_tenant}
      LEFT JOIN "SquareVariation" exception_link_square ON exception_link_square.id = "SkuLink"."squareVariationId" AND exception_link_square.tenant_id = #{quoted_tenant}
    SQL
    scope = scope.where(<<~SQL.squish)
      exception_link_shopify.id IS NULL OR exception_link_square.id IS NULL OR
      COALESCE(LOWER(TRIM("SkuLink".sku)), '') <> COALESCE(LOWER(TRIM(exception_link_shopify.sku)), '') OR
      COALESCE(LOWER(TRIM("SkuLink".sku)), '') <> COALESCE(LOWER(TRIM(exception_link_square.sku)), '') OR TRIM("SkuLink".sku) = ''
    SQL
    # An explicit unlink with a valid local Shopify parent is a decision,
    # not a broken half-link. Missing/foreign parents still require review.
    scope = scope.where(<<~SQL.squish)
      NOT ("SkuLink".auto IS FALSE AND COALESCE("SkuLink"."matchSource", '') = 'manual-unlink' AND
        "SkuLink"."squareVariationId" IS NULL AND exception_link_shopify.id IS NOT NULL)
    SQL
    bounded(scope.order(:sku, :id), 'Incomplete or inconsistent catalog links', checks).map do |link|
      { kind: 'Unresolved catalog link', severity: :warning, source: 'shopify / square', label: link.sku,
        item_id: link.shopifyVariantId, detail: "Link #{link.id} has an absent or inconsistent source identity/SKU. Shopify item #{link.shopifyVariantId.presence || 'unresolved'}; Square item #{link.squareVariationId.presence || 'unresolved'}. Review exact identities rather than assuming the SKU is unique.", review_type: :catalog }
    end
  end

  def shared_link_rows(checks)
    groups = SkuLink.linked.group(:squareVariationId).having('COUNT(DISTINCT "shopifyVariantId") > 1')
                    .order(:squareVariationId).limit(limit + 1).distinct.count(:shopifyVariantId)
    checks << { label: 'Square catalog items shared across Shopify variants', returned: [groups.length, limit].min, limited: groups.length > limit }
    groups.to_a.first(limit).map do |id, count|
      { kind: 'Shared Square identity', severity: :critical, source: 'square', item_id: id, label: 'Shared Square catalog item',
        detail: "Square item #{id} is linked to #{count} distinct Shopify variants. Its stock and sales cannot be attributed independently to every linked variant. Review the catalog links; do not duplicate this pool's capacity.", review_type: :catalog }
    end
  end

  def count_section
    checks = []
    scope = InventoryCount.where(status: 'pending')
    scope = scope.where(locationId: location_id) if location_id
    scope = scope.where(locationId: Location.where(source: source).select(:id)) if source
    counts = bounded(scope.order(:countedAt, :id).includes(:location), 'Pending physical count worksheets', checks)
    sizes = InventoryCountItem.where(countId: counts.map(&:id)).group(:countId).count
    rows = counts.map do |count|
      { kind: 'Count awaits review', severity: :notice, source: count.location&.source || 'unassigned', location_id: count.locationId,
        location_name: count.location&.name, item_id: count.id, label: count.note.presence || 'Pending physical inventory count',
        observed_at: count.countedAt, observed_label: 'Physically counted', review_type: :count, review_id: count.id,
        detail: "#{sizes.fetch(count.id, 0)} worksheet rows await review. Approval is an audit record only and does not change mirrored stock. Legacy count comparisons may use Shopify totals across locations; verify exact pool and SKU identity before relying on variance." }
    end
    section_result(:counts, rows, checks, 'Pending counts matching the source/location filter. A source filter excludes counts with no recognized location. This is a review queue, not an instruction to apply counts.')
  end

  def order_section
    checks = []
    scope = Core::Order.where(source: 'shopify', status: %w[paid fulfilled refunded], source_lines_complete: false)
    scope = scope.none if source == 'square'
    if location_id
      selected_location = Location.find_by(id: location_id, source: 'shopify')
      scope = selected_location ? scope.where(location_id: selected_location.externalId) : scope.none
    end
    rows = bounded(scope.order(occurred_at: :desc, id: :desc), 'Eligible Shopify orders without confirmed complete source lines', checks).map do |order|
      { kind: 'Incomplete source order lines', severity: :warning, source: 'shopify', item_id: order.source_order_id,
        location_id: order.location_id, location_name: order.location_id.present? ? 'Source order location (external ID)' : nil,
        label: order.display_number, observed_at: order.occurred_at, observed_label: 'Order dated', review_type: :order,
        review_id: order.id, review_day: order.occurred_at.in_time_zone.to_date.iso8601,
        detail: 'The imported source-line set has not been confirmed complete. Legacy or truncated order data must not drive gram consumption. Re-import complete source data and review exact line/variant identities before using a recipe; this queue does not deduct material.' }
    end
    section_result(:orders, rows, checks, 'Paid, fulfilled or refunded Shopify orders with source_lines_complete=false, newest first across all dates. The selected stock location is matched to the order location by Shopify external ID; unassigned order locations are excluded when filtering by location. Complete source lines alone do not guarantee recipe eligibility.')
  end

  def bulk_section
    checks = []
    scope = BulkLot.joins(:bulk_material).where(bulk_materials: { tenant_id: @tenant_id }).where(balance_mg: 0)
    rows = bounded(scope.order(:created_at, :id).includes(:bulk_material), 'Bulk lots with zero remaining balance', checks).map do |lot|
      { kind: 'Bulk lot depleted', severity: :notice, source: 'local bulk', item_id: lot.id,
        label: "#{lot.bulk_material.name} · #{lot.code}", observed_at: lot.created_at, observed_label: 'Lot received',
        review_type: :lot, review_id: lot.id, material_id: lot.bulk_material_id,
        detail: 'This local lot has zero milligrams remaining. Other lots may still hold this material; review lots before receiving more. This does not establish a reorder threshold or platform availability.' }
    end
    section_result(:bulk, rows, checks, 'Local bulk ledger across this store. Platform and location filters do not apply because bulk lots do not yet have platform/location assignments. Zero-balance historical lots remain visible.')
  end
end
