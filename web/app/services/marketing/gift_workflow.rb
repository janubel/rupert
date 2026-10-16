# frozen_string_literal: true

module Marketing
  class GiftWorkflow
    PUBLIC_FIELDS = %i[currency shipping_cost_cents note].freeze
    DELIVERY_FIELDS = (ProductGift::PRIVATE_FIELDS + [:carrier]).freeze

    def self.run(gift, actor:, version: nil, action:, attributes: {}, item_id: nil, note: nil)
      private_input = (attributes.keys.map(&:to_sym) & DELIVERY_FIELDS).any? || %w[confirm_recipient ready ship deliver return].include?(action)
      actor = CmsWriter.authorize!(actor, action == 'approve' ? 'marketing.review' : 'marketing.write', contacts: private_input)
      ProductGift.transaction do
        engagement = Engagement.find(gift.engagement_id)
        influencer = Influencer.lock.find(engagement.influencer_id)
        engagement.lock!
        CmsWriter.lock!(gift, version)
        gift.workflow_checked = true
        case action
        when 'save'
          require_status!(gift, %w[proposed approved ready_to_ship])
          gift.assign_attributes(attributes.slice(*(PUBLIC_FIELDS + DELIVERY_FIELDS)))
          if gift.status != 'proposed' && (gift.changes.keys & PUBLIC_FIELDS.map(&:to_s)).any?
            raise ReplyWorkflow::Invalid, 'Approved gift budget/details are locked. Cancel it and propose a new gift.'
          end
          if gift.status == 'ready_to_ship' && gift.will_save_change_to_shipping_details?
            raise ReplyWorkflow::Invalid, 'Shipping details are locked when ready to ship. Cancel and propose a new gift for another recipient.'
          end
        when 'add_item', 'update_item', 'remove_item'
          require_status!(gift, ['proposed'])
          raise ReplyWorkflow::Invalid, 'Save the gift first' if gift.new_record?

          write_item!(gift, action, attributes, item_id)
        when 'approve'
          require_status!(gift, ['proposed'])
          require_active!(engagement, influencer)
          rows = gift.items.to_a
          raise ReplyWorkflow::Invalid, 'Add at least one gift product (maximum 100).' if rows.empty? || rows.length > 100
          rows.each { |item| ShopifyVariant.find(item.source_variant_id) }
          gift.status = 'approved'
        when 'confirm_recipient'
          require_status!(gift, %w[proposed approved ready_to_ship])
          raise ReplyWorkflow::Invalid, 'Record recipient-confirmed shipping details first.' if gift.shipping_details.blank?

          gift.recipient_confirmed_at = Time.current
        when 'ready'
          require_status!(gift, ['approved'])
          require_active!(engagement, influencer)
          unless gift.shipping_details.present? && gift.recipient_confirmed_at && gift.recipient_confirmed_at > 90.days.ago
            raise ReplyWorkflow::Invalid, 'Confirm the recipient shipping details within 90 days.'
          end
          gift.status = 'ready_to_ship'
        when 'ship'
          require_status!(gift, ['ready_to_ship'])
          require_active!(engagement, influencer)
          unless gift.recipient_confirmed_at && gift.recipient_confirmed_at > 90.days.ago
            raise ReplyWorkflow::Invalid, 'Refresh recipient confirmation before shipping.'
          end
          raise ReplyWorkflow::Invalid, 'Record carrier and tracking number before marking shipped.' if gift.carrier.blank? || gift.tracking_number.blank?

          gift.assign_attributes(status: 'shipped', shipped_at: Time.current)
        when 'deliver'
          require_status!(gift, ['shipped'])
          gift.assign_attributes(status: 'delivered', delivered_at: Time.current)
        when 'cancel'
          require_status!(gift, %w[proposed approved ready_to_ship])
          raise ReplyWorkflow::Invalid, 'Add the cancellation reason.' if note.blank?

          gift.status = 'cancelled'
        when 'return'
          require_status!(gift, %w[shipped delivered])
          raise ReplyWorkflow::Invalid, 'Add the return reason.' if note.blank?

          gift.assign_attributes(status: 'returned', returned_at: Time.current)
        else
          raise ReplyWorkflow::Invalid, 'Unknown gift action'
        end
        raise ReplyWorkflow::Invalid, 'Reason is too long' if note.to_s.length > 3000

        gift.save!
        # Item-only changes must also invalidate old gift forms.
        gift.touch if %w[add_item update_item remove_item].include?(action)
        CmsWriter.event!(gift, actor, action, { gift: gift.attributes, items: gift.items.map(&:attributes), reason: note })
        gift
      end
    end

    def self.write_item!(gift, action, attributes, item_id)
      item = action == 'add_item' ? gift.items.new(tenant_id: Current.tenant_id) : gift.items.find(item_id)
      if action == 'remove_item'
        item.destroy!
        return
      end
      if action == 'add_item'
        raise ReplyWorkflow::Invalid, 'A gift can contain at most 100 products.' if gift.items.count >= 100

        variant = ShopifyVariant.find(attributes[:source_variant_id])
        item.assign_attributes(source_variant_id: variant.id, sku: variant.sku,
          product_name: [variant.product&.title, variant.title].compact.join(' · '))
      end
      item.workflow_checked = true
      item.assign_attributes(attributes.slice(:quantity, :unit_cost_cents))
      item.save!
    end

    def self.require_status!(gift, states)
      raise ReplyWorkflow::Invalid, 'This action is unavailable in the gift’s current state.' unless states.include?(gift.status)
    end

    def self.require_active!(engagement, influencer)
      raise ReplyWorkflow::Invalid, 'Activate the collaboration and check the influencer contact status.' unless engagement.status == 'active' && influencer.contactable?
    end
  end
end
