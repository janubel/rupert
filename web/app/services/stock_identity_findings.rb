# frozen_string_literal: true

require 'digest'
require 'json'

# Private, dated investigation notes and candidate links. Never an approved
# inventory mapping. Setting encrypts the payload; every lookup binds the
# tenant, source locations and the catalog identity observed during review.
class StockIdentityFindings
  PREFIX = 'stock_identity_findings_v1'
  MAX_BYTES = 2 * 1024 * 1024
  KINDS = %w[family package identifier].freeze

  attr_reader :reviewed_at, :status

  def self.key(shopify, ctrax)
    "#{PREFIX}:#{shopify.location_id}:#{ctrax.location_id}"
  end

  def self.scope_for(shopify, ctrax)
    { 'tenant_id' => Current.tenant_id, 'shopify_location_id' => shopify.location_id,
      'shop_domain' => shopify.shop_domain, 'ctrax_location_id' => ctrax.location_id,
      'api_origin' => ctrax.api_origin, 'store_id' => ctrax.store_id }
  end

  def self.shopify_signature(variant)
    Digest::SHA256.hexdigest([variant.id, variant.productId, variant.product&.title, variant.title, variant.sku,
      variant.barcode, variant.price&.to_s, variant.tracked, variant.catalog_present, variant.product&.catalog_present, variant.product&.status].to_json)
  end

  def self.ctrax_signature(record)
    Digest::SHA256.hexdigest(record.slice('id', 'product_id', 'name', 'product_name', 'sku', 'barcode', 'price_cents',
      'website_product_id', 'website_variant_id').sort.to_h.to_json)
  end

  # Called by a private, reviewed import, never by rendering the comparison.
  # Stock quantities, SKU links and provider clients are deliberately untouched.
  def self.publish!(shopify:, ctrax:, notes:, candidates:, reviewed_at:)
    snapshots = [shopify, ctrax]
    unless Current.tenant_id && snapshots.all? { |s| s.persisted? && s.tenant_id == Current.tenant_id && s.location.tenant_id == Current.tenant_id } &&
        shopify.location.source == 'shopify' && ctrax.location.source == 'ctrax'
      raise ArgumentError, 'Investigation sources must belong to the current workspace'
    end
    variants = ShopifyVariant.current_catalog.includes(:product).index_by(&:id)
    records = ctrax.records.index_by { |r| r.fetch('id') }
    bind = lambda do |entry|
      sid, cid = entry.values_at('shopify_id', 'ctrax_id')
      raise ArgumentError, 'Unknown investigation identity' unless (sid || cid) && (!sid || variants.key?(sid)) && (!cid || records.key?(cid))

      entry.merge('shopify_signature' => sid && shopify_signature(variants.fetch(sid)),
        'ctrax_signature' => cid && ctrax_signature(records.fetch(cid)))
    end
    unless notes.is_a?(Array) && notes.size <= 1000 && candidates.is_a?(Array) && candidates.size <= 1000
      raise ArgumentError, 'Investigation exceeds its bound'
    end
    saved_notes = notes.map do |entry|
      unless entry.is_a?(Hash) && entry['text'].is_a?(String) && entry['text'].bytesize.between?(1, 6000) &&
          %w[info warning].include?(entry['severity'])
        raise ArgumentError, 'Invalid investigation note'
      end

      bind.call(entry.slice('shopify_id', 'ctrax_id', 'text', 'severity'))
    end
    saved_candidates = candidates.map do |entry|
      unless entry.is_a?(Hash) && entry['shopify_id'] && entry['ctrax_id'] && KINDS.include?(entry['kind']) &&
          entry['evidence'].is_a?(String) && entry['evidence'].bytesize.between?(1, 6000)
        raise ArgumentError, 'Invalid investigation candidate'
      end

      bound = bind.call(entry.slice('shopify_id', 'ctrax_id', 'kind', 'evidence'))
      raise ArgumentError, 'Candidate must be a current tracked Shopify variant' unless variants.fetch(entry['shopify_id']).tracked

      bound
    end
    %w[shopify_id ctrax_id].each do |field|
      raise ArgumentError, 'Investigation candidates must be one-to-one' unless saved_candidates.map { |r| r[field] }.uniq.size == saved_candidates.size
    end
    at = Time.iso8601(reviewed_at.to_s)
    raise ArgumentError, 'Invalid investigation time' if at > Time.current + 5.minutes

    payload = { 'version' => 1, 'scope' => scope_for(shopify, ctrax), 'reviewed_at' => at.iso8601,
      'expires_at' => (at + 7.days).iso8601, 'notes' => saved_notes, 'candidates' => saved_candidates }.to_json
    raise ArgumentError, 'Investigation exceeds its bound' if payload.bytesize > MAX_BYTES

    Setting.find_or_create_for(key(shopify, ctrax), Current.tenant_id) { |setting| setting.value = payload }
  end

  def initialize(shopify:, ctrax:, catalog:, records:, at: Time.current)
    @variants = catalog.index_by(&:id)
    @records = records.index_by { |r| r.fetch('id') }
    @notes = []
    @candidates = {}
    return unless shopify && ctrax

    value = Setting.find_by(key: self.class.key(shopify, ctrax), tenant_id: Current.tenant_id)&.value
    return if value.blank?
    raise ArgumentError if value.bytesize > MAX_BYTES

    document = JSON.parse(value, max_nesting: 12)
    raise ArgumentError unless document['version'] == 1 && document['scope'] == self.class.scope_for(shopify, ctrax)

    @reviewed_at = Time.iso8601(document.fetch('reviewed_at'))
    expires_at = Time.iso8601(document.fetch('expires_at'))
    raise ArgumentError unless expires_at == @reviewed_at + 7.days

    @expired = at > expires_at || @reviewed_at > at + 5.minutes
    @notes = document.fetch('notes')
    candidates = document.fetch('candidates')
    raise ArgumentError unless @notes.is_a?(Array) && @notes.size <= 1000 && candidates.is_a?(Array) && candidates.size <= 1000
    raise ArgumentError unless (@notes + candidates).all? { |r| r.is_a?(Hash) }
    raise ArgumentError unless @notes.all? { |r| r['text'].is_a?(String) && r['text'].bytesize.between?(1, 6000) && %w[info warning].include?(r['severity']) }
    raise ArgumentError unless candidates.all? { |r| r['shopify_id'].is_a?(String) && r['ctrax_id'].is_a?(String) && r['evidence'].is_a?(String) && r['evidence'].bytesize.between?(1, 6000) }
    %w[shopify_id ctrax_id].each do |field|
      raise ArgumentError unless candidates.map { |r| r[field] }.uniq.size == candidates.size
    end
    @candidates = candidates.select { |r| KINDS.include?(r['kind']) && valid?(r) }.index_by { |r| r['shopify_id'] }
    @status = @expired ? 'Saved investigation needs a fresh source review; candidate links are withheld' : 'Saved investigation; candidate links are not approved stock mappings'
  rescue JSON::ParserError, ArgumentError, KeyError, TypeError, ActiveRecord::Encryption::Errors::Decryption
    @notes = []
    @candidates = {}
    @status = 'Saved investigation could not be verified; candidate links are withheld'
  end

  def candidate_for(id)
    @candidates[id]
  end

  def notes_for(variant, record)
    @notes.filter_map do |entry|
      next unless (variant && entry['shopify_id'] == variant.id) || (record && entry['ctrax_id'] == record['id'])

      { text: entry['text'], severity: entry['severity'], reviewed_at: reviewed_at, current: valid?(entry) }
    end.uniq { |note| note[:text] }
  end

  private

  def valid?(entry)
    return false if @expired

    sid, cid = entry.values_at('shopify_id', 'ctrax_id')
    (sid || cid) && (!sid || (@variants[sid] && entry['shopify_signature'] == self.class.shopify_signature(@variants[sid]))) &&
      (!cid || (@records[cid] && entry['ctrax_signature'] == self.class.ctrax_signature(@records[cid])))
  end
end
