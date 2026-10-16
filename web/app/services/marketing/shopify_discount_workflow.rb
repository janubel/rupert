# frozen_string_literal: true

module Marketing
  class ShopifyDiscountWorkflow
    def self.authorize!(actor, review: false)
      actor = CmsWriter.authorize!(actor, 'marketing.discounts')
      raise Pundit::NotAuthorizedError unless actor.can?('marketing.write') && (!review || actor.can?('marketing.review'))

      actor
    end

    def self.draft(engagement, attributes:, actor:)
      actor = authorize!(actor)
      active!(engagement)
      key = SecureRandom.uuid
      input = ShopifyDiscountTerms.build(attributes, title: "Rupert influencer #{engagement.influencer_id} / #{key}")
      api = ShopifyDiscountApi.new
      shop = api.shop
      ShopifyDiscount.transaction do
        engagement.influencer.lock!
        engagement.lock!
        active!(engagement)
        unless Urls.host(shop.dig('primaryDomain', 'url')) == Urls.host(engagement.campaign.storefront_url)
          raise ReplyWorkflow::Invalid, 'The campaign storefront must match this Shopify store’s verified primary domain.'
        end
        offer = engagement.offers.create!(tenant_id: Current.tenant_id, code: input['code'],
          starts_at: input['startsAt'], ends_at: input['endsAt'], destination_url: engagement.destination_url,
          terms: ShopifyDiscountTerms.summary(input, shop['currencyCode']))
        record = ShopifyDiscount.create!(tenant_id: Current.tenant_id, offer: offer, shop_domain: api.shop_domain,
          shop_id: shop['id'], currency: shop['currencyCode'], request_key: key, request_json: JSON.generate(input))
        CmsWriter.event!(record, actor, 'shopify_discount_drafted', { input: input, shop_id: shop['id'] })
        record
      end
    end

    def self.activate(record, actor:, version:, confirmed:)
      actor = authorize!(actor, review: true)
      raise ReplyWorkflow::Invalid, 'Confirm the displayed store, code and full offer terms before creating it in Shopify.' unless confirmed == '1'
      raise ActiveRecord::RecordNotFound unless record.tenant_id == Current.tenant_id

      api = ShopifyDiscountApi.new
      verify_shop!(record, api)
      ShopifyDiscount.transaction do
        lock_context!(record)
        CmsWriter.lock!(record, version)
        active!(record.offer.engagement)
        unless %w[draft failed].include?(record.status)
          raise ReplyWorkflow::Invalid, 'This code already has a creation attempt. Check the Shopify result instead of creating it again.'
        end
        raise ReplyWorkflow::Invalid, 'This draft expired. Prepare a new offer.' unless record.offer.ends_at > Time.current

        record.update!(status: 'creating', attempted_at: Time.current, approved_by_id: actor.id, last_error: nil)
        CmsWriter.event!(record, actor, 'shopify_creation_confirmed', { input: record.input, shop_id: record.shop_id })
      end
      # Commit the intent before the network call. An interrupted process leaves
      # a recoverable creating record, never a silent automatic re-create.
      begin
        existing = api.lookup(record.offer.code)
        if existing
          finish!(record, existing, actor)
        else
          Current.confirm_push!
          id = api.create(record.input)
          record.update!(remote_id: id)
          finish!(record, api.lookup(record.offer.code), actor)
        end
      rescue ShopifyDiscountApi::Rejected => error
        failure!(record, actor, 'failed', error.message)
      rescue ShopifyDiscountApi::Error => error
        failure!(record, actor, 'uncertain', error.message)
      ensure
        Current.metadata.delete(:push_confirmed)
      end
      record.reload
    end

    def self.refresh(record, actor:)
      actor = CmsWriter.authorize!(actor)
      raise ActiveRecord::RecordNotFound unless record.tenant_id == Current.tenant_id
      if record.status == 'draft' || (record.status == 'creating' && record.attempted_at && record.attempted_at > 2.minutes.ago)
        raise ReplyWorkflow::Invalid, 'Creation has not started or is still running. Reload before checking the result.'
      end

      api = ShopifyDiscountApi.new
      verify_shop!(record, api)
      finish!(record, api.lookup(record.offer.code), actor)
      record.reload
    rescue ShopifyDiscountApi::Error => error
      failure!(record, actor, record.remote_id.present? ? 'blocked' : 'uncertain', error.message)
      raise
    end

    def self.verify_shop!(record, api)
      shop = api.shop
      unless api.shop_domain == record.shop_domain && shop['id'] == record.shop_id && shop['currencyCode'] == record.currency &&
          Urls.host(shop.dig('primaryDomain', 'url')) == record.offer.merchant_host &&
          record.offer.merchant_host == Urls.host(record.offer.campaign.storefront_url)
        raise ReplyWorkflow::Invalid, 'The connected Shopify store, currency or campaign storefront changed. Restore the original connection before continuing.'
      end
    end

    def self.finish!(record, node, actor)
      unless ShopifyDiscountTerms.matches?(record, node)
        message = node ? 'The Shopify code differs from this reviewed offer. No code was overwritten. Check the merchant settings.' : 'No matching Shopify result yet. Check again before preparing another code; no retry was sent.'
        failure!(record, actor, node ? 'blocked' : 'uncertain', message)
        return
      end
      ShopifyDiscount.transaction do
        lock_context!(record)
        record.lock!
        record.update!(status: 'created', remote_id: node['id'], remote_status: node.dig('codeDiscount', 'status'),
          checked_at: Time.current, remote_json: JSON.generate(node), last_error: nil)
        record.offer.update!(evidence_url: record.admin_url)
        record.offer.update!(verified_at: Time.current, verified_by_id: actor.id)
        CmsWriter.event!(record, actor, 'shopify_result_verified', { remote_id: record.remote_id, status: record.remote_status })
      end
    end

    def self.failure!(record, actor, status, message)
      ShopifyDiscount.transaction do
        lock_context!(record)
        record.lock!
        record.update!(status: status, last_error: message, checked_at: Time.current)
        record.offer.update!(verified_at: nil, verified_by_id: nil)
        CmsWriter.event!(record, actor, 'shopify_result_needs_check', { status: status, message: message })
      end
    end

    def self.active!(engagement)
      raise ActiveRecord::RecordNotFound unless engagement.tenant_id == Current.tenant_id
      raise ReplyWorkflow::Invalid, 'Activate this collaboration and check the influencer contact status first.' unless engagement.shareable?
    end

    def self.lock_context!(record)
      raise ActiveRecord::RecordNotFound unless record.tenant_id == Current.tenant_id

      record.offer.engagement.influencer.lock!
      record.offer.engagement.lock!
      record.offer.lock!
    end
  end
end
