# frozen_string_literal: true

require 'digest'

# Resolves a keyboard-wedge scanner's exact SKU or mirrored Shopify barcode.
# Counts remain local audit worksheets; this never adjusts platform inventory.
class InventoryCountScan
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: :unprocessable_entity)
      super(message)
      @status = status
    end
  end

  MAX_QUANTITY = 2_147_483_647

  def resolve!(code)
    code = code.to_s.strip
    raise Error, 'Scan a barcode or enter an exact SKU.' if code.blank?
    raise Error, 'The scanned code is too long.' if code.length > 255

    matches = ShopifyVariant.where(sku: code).or(ShopifyVariant.where(barcode: code)).to_a
    if matches.any? { |variant| variant.sku.blank? }
      raise Error.new('A barcode match has no SKU. Resolve the catalog conflict before scanning.', status: :conflict)
    end

    skus = (matches.map(&:sku) + SquareVariation.where(sku: code).pluck(:sku) +
      SkuLink.where(sku: code).pluck(:sku)).reject(&:blank?).uniq
    if skus.empty?
      raise Error.new('No known SKU matches this code. Check the barcode or use the manual sheet.',
        status: :not_found)
    end
    if skus.many?
      raise Error.new('This code matches multiple SKUs. Resolve the catalog conflict before scanning.',
        status: :conflict)
    end

    sku = skus.first
    shopify = ShopifyVariant.includes(:product).where(sku: sku).to_a
    square = SquareVariation.includes(:item).where(sku: sku).to_a
    links = SkuLink.where(sku: sku).to_a
    shopify_ids = (shopify.map(&:id) + links.map(&:shopifyVariantId)).compact.uniq
    square_ids = (square.map(&:id) + links.map(&:squareVariationId)).compact.uniq
    if shopify_ids.many? || square_ids.many?
      raise Error.new('This SKU identifies multiple variants. Resolve the catalog conflict before scanning.',
        status: :conflict)
    end

    variant = ShopifyVariant.includes(:product).find_by(id: shopify_ids.first) if shopify_ids.any?
    variation = SquareVariation.includes(:item).find_by(id: square_ids.first) if square_ids.any?
    {
      sku: sku,
      title: [variant&.product&.title, variant&.title].compact.uniq.join(' · ').presence ||
        [variation&.item&.name, variation&.name].compact.uniq.join(' · ').presence || sku,
      shopifyVariantId: variant&.id,
      squareVariationId: variation&.id
    }
  end

  def record!(count:, code:, quantity:, mode:, request_token:, actor:)
    unless request_token.to_s.match?(/\A[a-zA-Z0-9_-]{16,64}\z/)
      raise Error, 'The scan request token is missing or invalid. Reload the scanner.'
    end
    raise Error, 'Choose add units or set total.' unless %w[increment set].include?(mode)
    unless quantity.to_s.match?(/\A\d+\z/) && quantity.to_i <= MAX_QUANTITY
      raise Error, 'Quantity must be a whole number between 0 and 2147483647.'
    end

    units = quantity.to_i
    raise Error, 'Add at least one unit, or choose set total to record zero.' if mode == 'increment' && units.zero?

    fingerprint = Digest::SHA256.hexdigest([code.to_s.strip, units, mode].to_json)
    count.with_lock do
      receipt = count.scan_receipts.find_by(request_token: request_token)
      if receipt
        unless receipt.fingerprint == fingerprint
          raise Error.new('This scan request was already used for a different entry. Reload the scanner.',
            status: :conflict)
        end

        return receipt.result.symbolize_keys
      end
      unless count.draft?
        raise Error.new('Only draft counts can be changed. Reopen a rejected count first.',
          status: :conflict)
      end

      ctrax = Ctrax::CountComparison.new(count) if count.location&.source == 'ctrax'
      match = ctrax ? ctrax.resolve!(code.to_s.strip) : resolve!(code)
      existing = if ctrax
        count.items.select { |row| ctrax.canonical_key(row.sku) == match[:sku] }
      else
        count.items.where(sku: match[:sku]).to_a
                 end
      if existing.many?
        raise Error.new('This worksheet has duplicate rows for this SKU. Combine them in Edit before scanning.',
          status: :conflict)
      end

      item = existing.first || count.items.build(sku: match[:sku])
      total = mode == 'set' ? units : item.quantity.to_i + units
      raise Error, 'The counted quantity is too large.' if total > MAX_QUANTITY

      attributes = match.slice(:shopifyVariantId, :squareVariationId).merge(quantity: total)
      attributes[:sku] = match[:sku] if ctrax
      attributes.merge!(ctrax.attributes_for(item)) if ctrax
      item.update!(attributes)
      result = match.merge(quantity: item.quantity, total_quantity: count.total_quantity, item_count: count.items.count)
      count.scan_receipts.create!(request_token: request_token, fingerprint: fingerprint, result: result,
        created_by: actor)
      result
    end
  end
end
