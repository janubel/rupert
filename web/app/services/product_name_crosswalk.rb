# frozen_string_literal: true

require 'csv'

# Read-only crosswalk of product names. The Shopify website catalog is primary;
# Square, SwipeSimple and C-Trax are secondary observations matched to it by
# SKU, then exact normalized name (C-Trax and SwipeSimple may also fuzzy match
# and are flagged for review). Nothing here writes to Rupert or any provider.
#
# The SwipeSimple Item Catalog has no sync job. It is read from an optional
# tab-separated file (storage/swipesimple_items.tsv or
# PRODUCT_NAMES_SWIPESIMPLE_FILE) with the headers
# name, sku, price, tax, count, tracked, category. It stays out of Git.
class ProductNameCrosswalk
  SYSTEMS = { square: 'Square', swipesimple: 'SwipeSimple', ctrax: 'C-Trax' }.freeze
  FUZZY_CUTOFF = 0.88
  SIMILAR_CUTOFF = 0.8
  CONFLICT_CUTOFF = 0.5
  SUGGESTION_CUTOFF = 0.5
  STOPWORDS = %w[the and of count regular].freeze

  def self.normalize(text)
    text.to_s.tr(" ", ' ').downcase.squish
      .gsub(/\([^)]*(thca|thc|%)[^)]*\)/, '')
      .gsub('&', ' and ').gsub('default title', '')
      .gsub(/(\d)\s*(grams?|gms?|g)\b/, '\1g')
      .gsub(/(\d)\s*(ounces?|ozs?)\b/, '\1oz')
      .gsub(/[^a-z0-9]+/, ' ').strip.delete_suffix(' regular')
  end

  def self.full_name(product, variant)
    product = product.to_s.squish
    variant = variant.to_s.squish
    variant.empty? || variant.casecmp?('default title') ? product : "#{product} - #{variant}"
  end

  # Sørensen–Dice similarity over character bigrams of the normalized names.
  def self.similarity(a, b)
    a = normalize(a)
    b = normalize(b)
    return 1.0 if a == b
    return 0.0 if a.length < 2 || b.length < 2

    dice(a, b, bigrams(a), bigrams(b))
  end

  def self.bigrams(normalized)
    normalized.chars.each_cons(2).map(&:join).tally
  end

  def self.dice(a, b, x, y)
    overlap = x.sum { |pair, n| [n, y.fetch(pair, 0)].min }
    2.0 * overlap / (a.length - 1 + b.length - 1)
  end

  attr_reader :swipesimple_read_at

  def initialize(swipesimple_file: nil)
    @swipesimple_file = Pathname(swipesimple_file || ENV['PRODUCT_NAMES_SWIPESIMPLE_FILE'].presence || Rails.root.join('storage/swipesimple_items.tsv'))
  end

  def swipesimple_available?
    swipesimple_items.any?
  end

  def ctrax_read_at
    ctrax_snapshot&.captured_at
  end

  def rows
    build
    @rows
  end

  def unmatched
    build
    @unmatched
  end

  # Secondary items with no website match, one per entry, grouped under any
  # suggested website name so items for the same product sit together.
  def unmatched_list
    SYSTEMS.keys.flat_map { |system| unmatched.fetch(system).map { |item| item.merge(system: system) } }
      .sort_by { |item| [self.class.normalize(item[:suggestion] || "\u{10FFFF}#{item[:name]}"), SYSTEMS.keys.index(item[:system])] }
  end

  # Matches the system is unsure about, for the verification sheet.
  def verify_rows
    rows.select { |row| row[:issues].any? }
  end

  def summary
    {
      website: rows.size,
      square: rows.count { |r| r[:square] }, square_total: @counts[:square],
      swipesimple: rows.count { |r| r[:swipesimple] }, swipesimple_total: @counts[:swipesimple],
      ctrax: rows.count { |r| r[:ctrax] }, ctrax_total: @counts[:ctrax],
      verify: verify_rows.size,
      unmatched: unmatched.values.sum(&:size)
    }
  end

  def csv
    CSV.generate do |out|
      out << ['Primary website name (Shopify)', 'Normalized name', 'Website SKU', 'Website variant ID',
        'Square name', 'Square match', 'Square comparison', 'SwipeSimple name', 'SwipeSimple match', 'SwipeSimple comparison',
        'SwipeSimple stock', 'C-Trax name', 'C-Trax match', 'C-Trax comparison', 'To review']
      rows.each do |row|
        out << [row[:name], row[:key], row[:sku], row[:variant_id],
          *%i[square swipesimple].flat_map { |s| match_cells(row[s]) }, row[:swipesimple]&.dig(:stock),
          *match_cells(row[:ctrax]), row[:issues].join('; ')].map { |value| value.is_a?(String) ? FinanceHelper.csv_safe(value) : value }
      end
    end
  end

  private

  def match_cells(match)
    [match&.dig(:name), match&.dig(:how), match&.dig(:comparison)]
  end

  def build
    return if @rows

    variants = ShopifyVariant.current_catalog.includes(:product).to_a
    @rows = variants.map do |variant|
      name = self.class.full_name(variant.product&.title, variant.title)
      { variant_id: variant.id, name: name, key: self.class.normalize(name), sku: variant.sku.to_s.strip, issues: [] }
    end
    @by_sku = @rows.select { |r| r[:sku].present? }.group_by { |r| r[:sku] }
    @by_key = @rows.group_by { |r| r[:key] }
    @keys = @by_key.keys
    @by_id = @rows.index_by { |r| r[:variant_id] }
    @unmatched = SYSTEMS.keys.index_with { [] }
    @counts = {}
    link_square
    link_each(:swipesimple, swipesimple_items)
    link_each(:ctrax, ctrax_items)
    @rows.each { |row| row[:issues] = issues_for(row) }
    @rows.sort_by! { |r| [r[:issues].any? ? 0 : 1, r[:key]] }
  end

  def link_square
    links = SkuLink.linked.pluck(:squareVariationId, :shopifyVariantId).to_h
    items = square_items
    @counts[:square] = items.size
    items.each do |item|
      target = @by_id[links[item[:id]]]
      how = 'SKU link' if target
      unless target
        target, how = unique_by_sku(item[:sku])
        target, how = unique_by_key(item[:name]) unless target
      end
      claim(:square, target, item, how)
    end
  end

  def link_each(system, items)
    @counts[system] = items.size
    items.each do |item|
      target, how = unique_by_sku(item[:sku])
      target, how = unique_by_key(item[:name]) unless target
      target, how = fuzzy(item[:name]) unless target
      claim(system, target, item, how)
    end
  end

  def unique_by_sku(sku)
    hits = sku.present? ? @by_sku.fetch(sku, []) : []
    hits.one? ? [hits.first, 'SKU'] : nil
  end

  def unique_by_key(name)
    hits = @by_key.fetch(self.class.normalize(name), [])
    hits.one? ? [hits.first, 'Name (exact normalized)'] : nil
  end

  def fuzzy(name)
    key = self.class.normalize(name)
    return if key.length < 2

    grams = self.class.bigrams(key)
    @key_grams ||= @keys.select { |k| k.length >= 2 }.index_with { |k| self.class.bigrams(k) }
    best, score = @key_grams.map { |candidate, g| [candidate, self.class.dice(key, candidate, grams, g)] }.max_by(&:last)
    return unless best && score >= FUZZY_CUTOFF && @by_key[best].one?

    [@by_key[best].first, 'Name (fuzzy, review)']
  end

  def claim(system, target, item, how)
    if target && target[system].nil?
      target[system] = item.merge(how: how, comparison: compare(target[:name], item[:name]))
    else
      @unmatched[system] << item.merge(suggestion: suggest(item[:name]))
    end
  end

  def compare(primary, other)
    return 'identical' if primary.squish == other.squish
    return 'format only' if self.class.normalize(primary) == self.class.normalize(other)

    self.class.similarity(primary, other) >= SIMILAR_CUTOFF ? 'similar' : 'different'
  end

  def issues_for(row)
    SYSTEMS.flat_map do |system, label|
      match = row[system]
      next [] unless match

      list = []
      list << "#{label} fuzzy match - verify" if match[:how].to_s.end_with?('review)')
      if match[:how].to_s.start_with?('SKU') && !match[:label_only] && self.class.similarity(row[:name], match[:name]) < CONFLICT_CUTOFF
        list << "#{label} SKU matches a very different name - verify (reused SKU?)"
      end
      list
    end
  end

  def suggest(name)
    tokens = tokens(name)
    return if tokens.empty?

    @token_sets ||= @rows.map { |row| [row, tokens(row[:name])] }
    row, set = @token_sets.max_by { |_, candidate| candidate.empty? ? 0 : (tokens & candidate).size.to_f / (tokens | candidate).size }
    score = (tokens & set).size.to_f / (tokens | set).size
    row[:name] if score >= SUGGESTION_CUTOFF
  end

  def tokens(name)
    self.class.normalize(name).split - STOPWORDS
  end

  def square_items
    sold = Core::OrderLine.joins(:order).where(orders: { source: 'square' })
      .where.not(source_variant_id: [nil, '']).where.not(name: [nil, ''])
      .order('orders.occurred_at').pluck(:source_variant_id, :name).to_h
    SquareVariation.includes(:item).map do |variation|
      sold_name = sold[variation.id]&.squish
      { id: variation.id, sku: variation.sku.to_s.strip, label_only: sold_name.nil?,
        name: sold_name || self.class.full_name(variation.item&.name, variation.name),
        note: sold_name ? 'Name as sold' : 'Catalog label only' }
    end
  end

  def ctrax_snapshot
    @ctrax_snapshot ||= CtraxStockSnapshot.order(captured_at: :desc).first
  end

  def ctrax_items
    (ctrax_snapshot&.records || []).map do |record|
      { id: record['id'].to_s, sku: record['sku'].to_s.strip, name: record['name'].to_s.squish, category: record['category'].to_s,
        note: record['listed'] == false ? 'Not listed for sale' : 'Listed' }
    end
  end

  def swipesimple_items
    @swipesimple_items ||= if @swipesimple_file.file?
      @swipesimple_read_at = @swipesimple_file.mtime
      CSV.read(@swipesimple_file, col_sep: "\t", headers: true, quote_char: "\0", encoding: 'bom|utf-8').filter_map do |line|
        name = line['name'].to_s.squish
        next if name.empty?

        tracked = line['tracked'].to_s == 'tracked'
        { id: line['sku'].to_s.strip, sku: line['sku'].to_s.strip, name: name, category: line['category'].to_s, stock: tracked ? line['count'].to_s : 'not tracked',
          note: [tracked ? "Stock #{line['count']}" : 'Not tracked', line['price']].compact_blank.join(' · ') }
      end
    else
      []
    end
  end
end
