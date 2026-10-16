# frozen_string_literal: true

module Marketing
  class ShopifyDiscountsController < BaseController
    before_action :set_engagement
    before_action :authorize_write, except: [:show]
    before_action :authorize_discounts, only: %i[new create activate]
    before_action :authorize_review, only: [:activate]

    def new
      @values = { code: "RUP-#{@engagement.influencer_id}-#{SecureRandom.hex(5).upcase}", kind: 'percentage',
                  minimum_subtotal: '0', usage_limit: '100', once_per_customer: '1', starts_at: Time.current, ends_at: 1.week.from_now }
    end

    def create
      record = ShopifyDiscountWorkflow.draft(@engagement, actor: Current.user,
        attributes: params.require(:discount).permit(*ShopifyDiscountTerms::FIELDS).to_h.symbolize_keys)
      redirect_to(marketing_engagement_shopify_discount_path(@engagement, record), notice: 'Draft saved. Review the exact terms before creating the code in Shopify.')
    end

    def show
      @record = scoped_record
    end

    def activate
      record = ShopifyDiscountWorkflow.activate(scoped_record, actor: Current.user, version: params[:lock_version], confirmed: params[:confirmed])
      redirect_to(marketing_engagement_shopify_discount_path(@engagement, record), notice: result_notice(record))
    end

    def refresh
      record = ShopifyDiscountWorkflow.refresh(scoped_record, actor: Current.user)
      redirect_to(marketing_engagement_shopify_discount_path(@engagement, record), notice: result_notice(record))
    end

    private

    def set_engagement
      @engagement = Engagement.find(params[:engagement_id])
    end

    def scoped_record
      ShopifyDiscount.joins(:offer).where(marketing_offers: { engagement_id: @engagement.id }).find(params[:id])
    end

    def authorize_discounts
      authorize(:module, :marketing_discounts?)
    end

    def result_notice(record)
      record.status == 'created' ? 'Shopify code and reviewed terms verified. Shopify enforces its active dates and usage limits.' : 'This code needs a Shopify result check. Review its status before sharing.'
    end
  end
end
