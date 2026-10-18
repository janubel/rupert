# frozen_string_literal: true

require 'digest'

# Cumulative received totals make a retried browser submission safe. Every
# increase is retained as an immutable delivery; totals cannot move backwards.
class PurchaseReceiving
  class Error < StandardError; end

  def self.call(order:, totals:, token:, actor:)
    unless order.tenant_id == Current.tenant_id && actor&.active? && (actor.tenant_id == Current.tenant_id || actor.super_admin?) &&
        actor.can?('purchasing.read') && actor.can?('purchasing.write')
      raise Error, 'Purchasing read and write permissions are required.'
    end
    raise Error, 'Reload the form for a valid receipt token.' unless token.to_s.match?(/\A[\w-]{1,100}\z/)
    raise Error, 'Enter received totals for this order.' unless totals.is_a?(Hash) && totals.any?

    normalized = totals.transform_keys(&:to_s).transform_values(&:to_s).sort.to_h
    digest = Digest::SHA256.hexdigest(normalized.to_json)
    Purchasing::PurchaseOrder.transaction(requires_new: true) do
      Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      prior = Purchasing::PurchaseDelivery.find_by(request_token: token)
      if prior
        unless prior.purchase_order_id == order.id && prior.payload_digest == digest && prior.actor == actor.email
          raise Error, 'This receipt token was already used for different quantities. Reload the order.'
        end
        return prior
      end
      order.reload
      raise Error, 'Only placed purchase orders can receive deliveries.' unless order.status == 'ordered'

      lines = order.lines.index_by { |line| line.id.to_s }
      changes = normalized.to_h do |id, quantity|
        line = lines[id]
        unless line && quantity.match?(/\A\d+\z/) && quantity.to_i.between?(line.received_quantity, line.quantity)
          raise Error, 'Received totals must be whole units, never decrease, and never exceed this order.'
        end
        [id, quantity.to_i - line.received_quantity]
      end
      raise Error, 'No additional units were received.' unless changes.values.any?(&:positive?)

      changes.each { |id, delta| lines[id].update!(received_quantity: lines[id].received_quantity + delta) }
      delivery = Purchasing::PurchaseDelivery.create!(purchase_order: order, tenant_id: order.tenant_id,
        request_token: token, payload_digest: digest, actor: actor.email, quantities_json: changes)
      order.mark_received! if order.fully_received?
      ActivityLogger.log('po_received', subject: order, actor: actor, details: "Delivery ##{delivery.id}: #{changes.values.sum} units recorded locally")
      delivery
    end
  end
end
