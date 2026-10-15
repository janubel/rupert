# frozen_string_literal: true

require 'digest'
require 'json'
require 'set'

# Reviewed local deductions only. No sync hook, remote inventory write, or
# automatic refund/restock operation is provided by this service.
class BulkSaleConsumption
  Error = Class.new(ArgumentError)
  MAX_AUDIT_RECEIPTS = 100
  Plan = Struct.new(:order, :line, :recipe, :lot, :source_line_id, :quantity,
    :required_mg, :available_mg, :source_fingerprint, :fingerprint, keyword_init: true) do
    def shortage_mg
      [required_mg - available_mg, 0].max
    end
  end
  ORDER_ID = %r{\Agid://shopify/Order/[1-9][0-9]*\z}
  LINE_ID = %r{\Agid://shopify/LineItem/[1-9][0-9]*\z}
  VARIANT_ID = %r{\Agid://shopify/ProductVariant/[1-9][0-9]*\z}
  REQUEST_TOKEN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  class << self
    def preview(order_id:, source_line_id:, lot_id:, recipe_id: nil)
      require_tenant!
      build_plan(Core::Order.find(order_id), source_line_id, BulkLot.find(lot_id), recipe_id)
    end

    # Bounded, read-only current-source comparison. Historical recipes and
    # movements stay unchanged even when the source requires operator review.
    def audit_states(receipts)
      require_tenant!
      items = if receipts.is_a?(ActiveRecord::Relation)
        receipts.limit([receipts.limit_value || MAX_AUDIT_RECEIPTS + 1, MAX_AUDIT_RECEIPTS + 1].min).to_a
      else
        Array(receipts)
      end
      raise Error, 'Review at most 100 material-use receipts at a time.' if items.length > MAX_AUDIT_RECEIPTS
      unless items.all? { |receipt| receipt.is_a?(BulkConsumption) && receipt.persisted? && receipt.tenant_id == Current.tenant_id }
        raise ActiveRecord::RecordNotFound
      end
      return {} if items.empty?

      orders = Core::Order.where(source: 'shopify', source_order_id: items.map(&:source_order_id).uniq)
        .includes(:order_lines).to_a
      by_identity = orders.index_by { |order| [order.source, order.source_order_id] }
      lines = orders.to_h { |order| [order.id, order.order_lines.to_a.group_by(&:source_line_id)] }
      refunded = Core::Refund.unscoped.where(tenant_id: Current.tenant_id, order_id: orders.map(&:id)).pluck(:order_id).to_set
      items.to_h do |receipt|
        order = by_identity[[receipt.source, receipt.source_order_id]]
        candidates = order ? lines.fetch(order.id).fetch(receipt.source_line_id, []) : []
        [receipt.id, audit_state_for(receipt, order, candidates, refunded)]
      end
    end

    def apply!(order_id:, source_line_id:, lot_id:, actor:, request_token:, recipe_id: nil, expected_fingerprint: nil)
      require_tenant!
      unless request_token.is_a?(String) && REQUEST_TOKEN.match?(request_token) &&
          actor.is_a?(String) && actor.present? && actor.bytesize <= 254 && !actor.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'A valid review request and recorded operator are required.'
      end
      result = nil
      BulkConsumption.transaction do
        # The canonical importer holds this same parent row throughout its
        # snapshot replacement. Lock it before reading any source-line state.
        locked = Core::Order.where(id: order_id).update_all(updated_at: Arel.sql('updated_at'))
        raise ActiveRecord::RecordNotFound unless locked == 1

        order = Core::Order.find(order_id)
        lot = BulkLot.find(lot_id)
        lot.serialize_movement do
          plan = build_plan(order, source_line_id, lot, recipe_id)
          if expected_fingerprint && expected_fingerprint != plan.fingerprint
            raise Error, 'The source sale, recipe or selected lot changed after review. Review the current details again.'
          end
          token_receipt = BulkConsumption.find_by(request_token: request_token)
          if token_receipt && (token_receipt.request_fingerprint != plan.fingerprint || token_receipt.created_by != actor)
            raise Error, 'This review request was already used for different consumption details.'
          end
          existing = BulkConsumption.find_by(source: 'shopify', source_order_id: order.source_order_id, source_line_id: source_line_id)
          if existing
            unless existing.request_fingerprint == plan.fingerprint
              raise Error, 'This sale line was already consumed with different details. Review a separate material correction.'
            end
            result = existing
            next
          end
          raise Error, 'This review request was already used for another sale line.' if token_receipt
          raise Error, 'The selected lot has insufficient material. No consumption was recorded.' if lot.balance_mg < plan.required_mg

          movement = BulkLedger.record(lot: lot, attributes: {
            kind: 'consume', quantity: plan.required_mg.to_s, unit: 'mg',
            reference: "Reviewed sale consumption #{request_token}", request_token: request_token
          }, actor: actor)
          unless movement.persisted? && movement.errors.empty?
            raise Error, 'The ledger could not record this consumption safely. No material was consumed.'
          end
          result = BulkConsumption.create!(
            tenant_id: Current.tenant_id, source: 'shopify', source_order_id: order.source_order_id,
            source_line_id: source_line_id, source_variant_id: plan.line.source_variant_id,
            order_number: order.order_number, quantity: plan.quantity, bulk_recipe: plan.recipe,
            bulk_lot: lot, bulk_movement: movement, mg_per_unit: plan.recipe.mg_per_unit,
            consumed_mg: plan.required_mg, source_fingerprint: plan.source_fingerprint,
            request_fingerprint: plan.fingerprint, request_token: request_token, created_by: actor,
            consumption_checked: true
          )
        end
      end
      result
    rescue ActiveRecord::RecordNotUnique
      raise Error, 'A consumption or movement request was already recorded. Reload its audit history before retrying.', cause: nil
    rescue ActiveRecord::RecordInvalid
      raise Error, 'The consumption audit could not be recorded safely. No material was consumed.', cause: nil
    rescue ActiveRecord::StatementInvalid
      raise Error, 'The stock ledger is busy or changed during review. No consumption was recorded; reload before retrying.', cause: nil
    end

    private

    def require_tenant!
      raise ActiveRecord::RecordNotFound unless Current.tenant_id.present? && Current.tenant&.status == 'active'
    end

    def build_plan(order, source_line_id, lot, recipe_id)
      unless order.source == 'shopify' && order.source_lines_complete && order.source_financial_status == 'PAID' &&
          %w[paid fulfilled].include?(order.status) && ORDER_ID.match?(order.source_order_id.to_s)
        raise Error, 'Only complete, quantity-consistent, paid Shopify source orders are eligible for reviewed material consumption.'
      end
      if Core::Refund.unscoped.where(tenant_id: Current.tenant_id, order_id: order.id).exists?
        raise Error, 'This order has refund history. Review its material disposition separately; refunds do not restock raw material.'
      end
      unless source_line_id.is_a?(String) && LINE_ID.match?(source_line_id)
        raise Error, 'An exact Shopify source line identity is required; SKU matching is not sufficient.'
      end
      lines = order.order_lines.where(source_line_id: source_line_id).to_a
      raise Error, 'The source sale line is missing or ambiguous. Refresh and review the imported order.' unless lines.one?

      line = lines.first
      unless VARIANT_ID.match?(line.source_variant_id.to_s) && line.quantity.is_a?(Integer) && line.quantity.between?(1, 2_147_483_647)
        raise Error, 'The source sale line requires an exact variant and a known positive whole-unit quantity.'
      end
      variant = ShopifyVariant.find_by(id: line.source_variant_id)
      unless variant&.product && variant.tenant_id == Current.tenant_id && variant.product.tenant_id == Current.tenant_id
        raise Error, 'The exact source variant is unavailable in this store catalog. Resolve its identity before consuming material.'
      end
      recipe = BulkRecipe.where(source: 'shopify', source_variant_id: line.source_variant_id)
        .where('effective_from <= ?', order.occurred_at).order(effective_from: :desc, version: :desc).first
      raise Error, 'No recipe version was effective at this sale time. Create and review the appropriate recipe first.' unless recipe
      if recipe_id && recipe.id.to_s != recipe_id.to_s
        raise Error, 'The selected recipe is not the effective version for this sale. Review the current recipe details.'
      end
      if lot.bulk_material_id != recipe.bulk_material_id
        raise Error, 'The selected lot does not contain the material required by this exact variant recipe.'
      end
      required_mg = recipe.mg_per_unit * line.quantity
      raise Error, 'The required material weight exceeds the supported range.' unless required_mg.between?(1, BulkMass::MAX_MG)

      source_fingerprint = source_digest(order, line)
      fingerprint = digest(source_fingerprint: source_fingerprint, recipe_id: recipe.id, recipe_version: recipe.version,
        material_id: recipe.bulk_material_id, mg_per_unit: recipe.mg_per_unit, lot_id: lot.id)
      Plan.new(order: order, line: line, recipe: recipe, lot: lot, source_line_id: source_line_id,
        quantity: line.quantity, required_mg: required_mg, available_mg: lot.balance_mg,
        source_fingerprint: source_fingerprint, fingerprint: fingerprint).freeze
    end

    def audit_state_for(receipt, order, lines, refunded)
      unless order
        return audit_review('Source order is unavailable. Review the recorded material use; no stock was changed.')
      end
      if refunded.include?(order.id)
        return audit_review('Refund history requires material disposition review; no material was automatically restocked.')
      end
      unless lines.one?
        return audit_review('Source line is missing or ambiguous. Review the recorded material use; no stock was changed.')
      end
      unless order.source_lines_complete && order.source_financial_status == 'PAID' && %w[paid fulfilled].include?(order.status)
        return audit_review('Source payment or completeness changed. Review the recorded material use; no stock was changed.')
      end
      line = lines.first
      unless line.quantity.is_a?(Integer) && line.quantity.between?(1, 2_147_483_647) && order.occurred_at &&
          source_digest(order, line) == receipt.source_fingerprint
        return audit_review('Source variant, quantity or order time changed. Review the recorded material use; no stock was changed.')
      end
      { status: 'matches', message: 'Current imported source snapshot matches the recorded consumption.' }
    end

    def audit_review(message)
      { status: 'review', message: message }
    end

    def source_digest(order, line)
      digest(source: order.source, order: order.source_order_id, line: line.source_line_id,
        variant: line.source_variant_id, quantity: line.quantity, occurred_at: order.occurred_at.utc.iso8601(6),
        source_financial_status: order.source_financial_status, complete: order.source_lines_complete)
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(value))
    end
  end
end
