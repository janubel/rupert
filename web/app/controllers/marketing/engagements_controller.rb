# frozen_string_literal: true

module Marketing
  class EngagementsController < BaseController
    before_action :authorize_write, only: %i[new create edit update copy]

    def show
      @engagement = Engagement.find(params[:id])
      @gifts = @engagement.product_gifts.order(created_at: :desc).limit(31).to_a
      @offers = @engagement.offers.includes(:shopify_discount).order(created_at: :desc).limit(31).to_a
      scope = @engagement.documents
      scope = scope.where(visibility: 'internal') unless Current.user.can?('marketing.contacts')
      @documents = scope.order(updated_at: :desc).limit(31).to_a
    end

    def new
      influencer = Influencer.find(params[:influencer_id])
      @record = influencer.engagements.new
      prepare_form
    end

    def create
      influencer = Influencer.find(params[:influencer_id])
      record = CmsWriter.write(influencer.engagements.new, actor: Current.user, attributes: attributes)
      redirect_to(marketing_engagement_path(record), notice: 'Collaboration created.')
    end

    def edit
      @record = Engagement.find(params[:id])
      prepare_form
    end

    def update
      record = CmsWriter.write(Engagement.find(params[:id]), actor: Current.user, attributes: attributes, version: params.dig(:cms_record, :lock_version))
      redirect_to(marketing_engagement_path(record), notice: 'Collaboration updated.')
    end

    def copy
      engagement = Engagement.find(params[:id])
      @copy = CmsWriter.copy_engagement(engagement, actor: Current.user)
      @back_url = marketing_engagement_path(engagement)
      render('marketing/cms/copy')
    end

    private

    def attributes
      params.require(:cms_record).permit(*CmsWriter::ENGAGEMENT_FIELDS).to_h.symbolize_keys
    end

    def prepare_form
      @form_url = @record.persisted? ? marketing_engagement_path(@record) : marketing_influencer_engagements_path(@record.influencer)
      @back_url = marketing_influencer_path(@record.influencer)
      render('marketing/cms/form')
    end
  end
end
