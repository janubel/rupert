# frozen_string_literal: true

# Suggestions are calculated from this tenant's observations; nothing is saved
# and no result is an approved stock mapping.
class StockIdentityMatcher
  Match = Struct.new(:record, :identity, :evidence, :issues, :priority, keyword_init: true)

  def initialize(catalog:, records:, historical: [], findings: nil)
    @catalog = catalog
    @records = records
    @historical = historical
    @findings = findings
    @variant_evidence = (catalog + historical).index_with { |v| StockIdentityEvidence.new(variant_name(v)) }
    @record_evidence = records.index_with { |r| StockIdentityEvidence.new(r['name'], product_name: r['product_name']) }
    @variant_aliases = catalog.index_with { |v| StockIdentityEvidence.aliases(v.sku, v.barcode) }
    @record_aliases = records.index_with { |r| StockIdentityEvidence.aliases(r['sku'], r['barcode']) }
    @v_alias_index = alias_index(@variant_aliases)
    @c_alias_index = alias_index(@record_aliases)
    @v_names = catalog.group_by { |v| @variant_evidence[v].key }
    @c_names = records.group_by { |r| @record_evidence[r].key }
    @h_names = historical.group_by { |v| @variant_evidence[v].key }
    @h_alias_index = alias_index(historical.index_with { |v| StockIdentityEvidence.aliases(v.sku, v.barcode) })
    @h_native = historical.group_by { |v| native_id(v.id) }
    @native = records.select { |r| r['website_variant_id'].present? }.group_by { |r| native_id(r['website_variant_id']) }
    @blocked_records = Hash.new { |h, k| h[k] = [] }
  end

  def matches
    @matches ||= begin
      proposals = @catalog.index_with do |variant|
        match = propose(variant)
        match.record ? match : investigated(variant, match)
      end
      proposals.values.select(&:record).group_by { |m| m.record.fetch('id') }.each_value do |claims|
        next if claims.one?

        best = claims.map(&:priority).min
        winners = claims.select { |claim| claim.priority == best }
        claims.each do |claim|
          next if winners.one? && claim == winners.first

          claim.record = nil
          claim.identity = 'Shared or conflicting identity'
          claim.issues << 'Another current item claims this source record'
        end
      end
      proposals.transform_keys(&:id)
    end
  end

  def unmatched(record)
    matches
    blocked = @blocked_records[record.fetch('id')].uniq
    old = historical_matches(record)
    if blocked.any?
      identity = blocked.join('; ')
    elsif old.any?
      identity = 'Historical Shopify candidate only'
    elsif @record_evidence[record].key.nil?
      identity = 'No unique identifier; explicit package missing'
    elsif @c_names[@record_evidence[record].key].size > 1
      identity = 'Ambiguous product/package'
    else
      identity = 'No compatible current Shopify candidate'
    end
    { identity: identity, historical: old.first(3).map { |v| { id: v.id, label: variant_name(v), status: v.product&.status, present: v.catalog_present, product_present: v.product&.catalog_present } },
      evidence: old.any? ? ["#{old.size} historical Shopify candidate(s); excluded from current stock"] : [] }
  end

  def variant_evidence(variant) = @variant_evidence.fetch(variant)
  def record_evidence(record) = @record_evidence.fetch(record)

  private

  def investigated(variant, original)
    proposal = @findings&.candidate_for(variant.id)
    return original unless proposal
    allowed = ['No unique identifier; explicit package missing', 'No compatible current C-Trax candidate']
    allowed << 'Ambiguous identifiers' if proposal['kind'] == 'identifier'
    return original unless allowed.include?(original.identity)

    record = @records.find { |r| r['id'] == proposal['ctrax_id'] }
    return original unless record && !source_conflict?(variant, record)
    left = @variant_evidence.fetch(variant)
    right = @record_evidence.fetch(record)
    return original if left.package_conflict?(right) || left.descriptor_conflict?(right)

    identity = "Investigated #{proposal.fetch('kind')} candidate"
    match = candidate(variant, record, identity, 2, [proposal.fetch('evidence'), 'Dated source investigation; not an approved stock mapping'])
    match.issues << 'Package equivalence unverified; quantity difference withheld' if proposal['kind'] == 'family'
    match
  end

  def native_id(value) = value.to_s.split('/').last.presence
  def variant_name(variant) = [variant.product&.title, variant.title].compact.join(' · ')

  def alias_index(aliases)
    index = Hash.new { |h, k| h[k] = [] }
    aliases.each { |item, keys| keys.each { |key| index[key] << item } }
    index
  end

  def reject_match(identity, records = [])
    records.each { |record| @blocked_records[record.fetch('id')] << identity }
    Match.new(identity: identity, evidence: [], issues: [], priority: 9)
  end

  def source_conflict?(variant, record)
    (record['website_variant_id'].present? && native_id(record['website_variant_id']) != native_id(variant.id)) ||
      (record['website_product_id'].present? && native_id(record['website_product_id']) != native_id(variant.productId))
  end

  def conflict_reason(variant, record)
    if record['website_variant_id'].present? && native_id(record['website_variant_id']) != native_id(variant.id)
      'Conflicting source ID'
    else
      'Conflicting source product ID'
    end
  end

  def propose(variant)
    direct = @native.fetch(native_id(variant.id), [])
    return reject_match('Ambiguous source IDs', direct) if direct.many?
    if direct.one?
      return reject_match('Conflicting source product ID', direct) if source_conflict?(variant, direct.first)

      return candidate(variant, direct.first, 'Source variant ID', 0, ['Exact native Shopify variant ID'])
    end
    aliases = @variant_aliases.fetch(variant)
    records = aliases.flat_map { |key| @c_alias_index[key] }.uniq
    if records.any?
      return reject_match('Conflicting or duplicate identifiers', records) unless records.one?

      record = records.first
      shared = aliases & @record_aliases.fetch(record)
      unless shared.all? { |key| @v_alias_index[key].one? && @c_alias_index[key].one? }
        return reject_match('Ambiguous identifiers', records)
      end
      return reject_match(conflict_reason(variant, record), records) if source_conflict?(variant, record)

      identity = shared.any? { |kind, _| kind == :sku } ? 'SKU candidate' : 'Barcode candidate'
      return candidate(variant, record, identity, 1, shared.map { |kind, value| "Exact #{kind.to_s.upcase}: #{value}" })
    end
    key = @variant_evidence[variant].key
    return reject_match('No unique identifier; explicit package missing') unless key

    named = @c_names.fetch(key, [])
    return reject_match('Ambiguous product/package', named) if named.many? || (named.any? && @v_names[key].many?)
    return reject_match('No compatible current C-Trax candidate') if named.empty?

    record = named.first
    return reject_match(conflict_reason(variant, record), named) if source_conflict?(variant, record)
    unless @variant_evidence[variant].compatible?(@record_evidence[record])
      return reject_match('Conflicting potency, grade or package', named)
    end

    candidate(variant, record, 'Name/package candidate', 2,
      ["Exact normalized product words: #{key.first}", "Exact explicit package: #{@variant_evidence[variant].package_label}"])
  end

  def candidate(variant, record, identity, priority, evidence)
    left = @variant_evidence[variant]
    right = @record_evidence[record]
    issues = []
    left_gtins = @variant_aliases[variant].select { |kind, _| kind == :gtin }.map(&:last)
    right_gtins = @record_aliases[record].select { |kind, _| kind == :gtin }.map(&:last)
    if left_gtins.many? || right_gtins.many? || (left_gtins.any? && right_gtins.any? && (left_gtins & right_gtins).empty?)
      return reject_match('Conflicting barcode identifiers', [record])
    end
    issues << 'Package sizes differ; quantity difference withheld' if left.package_conflict?(right)
    issues << 'Potency or grade conflicts; quantity difference withheld' if left.descriptor_conflict?(right)
    issues << 'Package/dose details missing from one source' if left.packages != right.packages && !left.package_conflict?(right)
    issues << 'Potency/grade details differ or are missing' if left.potencies != right.potencies || left.descriptors != right.descriptors
    issues << 'Name/package equivalence needs review; quantity difference withheld' if priority == 2
    left_price = variant.price && (BigDecimal(variant.price.to_s) * 100).round.to_i
    issues << 'Source prices differ' if left_price && record['price_cents'] && left_price != record['price_cents']
    own_keys = @variant_aliases.fetch(variant)
    issues << 'Shopify identifier is reused' if own_keys.any? { |key| @v_alias_index[key].many? }
    Match.new(record: record, identity: identity, evidence: evidence.uniq, issues: issues, priority: priority)
  end

  def historical_matches(record)
    keys = @record_aliases.fetch(record)
    evidence = @record_evidence[record]
    direct = record['website_variant_id'].present? ? @h_native.fetch(native_id(record['website_variant_id']), []) : []
    aliases = keys.flat_map { |key| @h_alias_index[key] }
    named = evidence.key ? @h_names.fetch(evidence.key, []).select { |v| evidence.compatible?(@variant_evidence[v]) } : []
    (direct + aliases + named).uniq.reject { |variant| source_conflict?(variant, record) }
  end
end
