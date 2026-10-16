# frozen_string_literal: true

module Marketing
  class ProductGiftsController < BaseController
    before_action :authorize_write, only: %i[new create edit update item transition]

    def show
      @gift = ProductGift.find(params[:id])
      scope = ShopifyVariant.order(:sku, :id)
      if params[:q].present?
        query = "%#{ShopifyVariant.sanitize_sql_like(params[:q].to_s.first(200))}%"
        scope = scope.where('sku LIKE :q OR title LIKE :q', q: query)
      end
      @variants = scope.includes(:product).limit(51).to_a if Current.user.can?('marketing.write') && @gift.status == 'proposed'
    end

    def new
      engagement = Engagement.find(params[:engagement_id])
      @record = engagement.product_gifts.new
      @record.shipping_details = engagement.influencer.shipping_details if Current.user.can?('marketing.contacts')
      prepare_form
    end

    def edit
      @record = ProductGift.find(params[:id])
      prepare_form
    end

    def create
      gift = Engagement.find(params[:engagement_id]).product_gifts.new
      GiftWorkflow.run(gift, actor: Current.user, action: 'save', attributes: attributes)
      redirect_to(marketing_product_gift_path(gift), notice: 'Gift proposed. Add its products before approval.')
    end

    def update
      gift = ProductGift.find(params[:id])
      GiftWorkflow.run(gift, actor: Current.user, action: 'save', attributes: attributes, version: params.dig(:cms_record, :lock_version))
      redirect_to(marketing_product_gift_path(gift), notice: 'Gift details saved.')
    end

    def item
      gift = ProductGift.find(params[:id])
      raise ReplyWorkflow::Invalid, 'Choose a product action.' unless %w[add_item update_item remove_item].include?(params[:item_action])

      attrs = params.fetch(:gift_item, ActionController::Parameters.new).permit(:source_variant_id, :quantity, :unit_cost_cents).to_h.symbolize_keys
      GiftWorkflow.run(gift, actor: Current.user, action: params[:item_action], version: params[:lock_version], attributes: attrs, item_id: params[:item_id])
      redirect_to(marketing_product_gift_path(gift), notice: 'Gift products updated.')
    end

    def transition
      gift = ProductGift.find(params[:id])
      action = params[:gift_action].to_s
      raise ReplyWorkflow::Invalid, 'Choose a gift action.' unless %w[approve confirm_recipient ready ship deliver cancel return].include?(action)
      if %w[ship deliver confirm_recipient].include?(action) && params[:confirmed] != '1'
        raise ReplyWorkflow::Invalid, 'Confirm the recipient or shipment evidence before recording this action.'
      end
      GiftWorkflow.run(gift, actor: Current.user, action: action, version: params[:lock_version], note: params[:reason])
      redirect_to(marketing_product_gift_path(gift), notice: 'Gift workflow updated. Stock and platform orders were not changed.')
    end

    private

    def attributes
      params.require(:cms_record).permit(*(GiftWorkflow::PUBLIC_FIELDS + GiftWorkflow::DELIVERY_FIELDS)).to_h.symbolize_keys
    end

    def prepare_form
      @form_url = @record.persisted? ? marketing_product_gift_path(@record) : marketing_engagement_product_gifts_path(@record.engagement)
      @back_url = @record.persisted? ? marketing_product_gift_path(@record) : marketing_engagement_path(@record.engagement)
      render('marketing/cms/form')
    end
  end
end
