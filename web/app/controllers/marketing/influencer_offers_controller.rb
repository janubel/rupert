# frozen_string_literal: true

module Marketing
  class InfluencerOffersController < BaseController
    before_action :set_engagement
    before_action :authorize_write, except: [:verify]

    def new
      @record = @engagement.offers.new(destination_url: @engagement.destination_url, starts_at: Time.current, ends_at: 1.week.from_now)
      prepare_form
    end

    def edit
      @record = @engagement.offers.find(params[:id])
      prepare_form
    end

    def create
      InfluencerOfferWriter.write(@engagement.offers.new, actor: Current.user, attributes: attributes)
      redirect_to(marketing_engagement_path(@engagement), notice: 'Temporary code record saved. Confirm merchant evidence before sharing.')
    end

    def update
      InfluencerOfferWriter.write(@engagement.offers.find(params[:id]), actor: Current.user, attributes: attributes, version: params.dig(:cms_record, :lock_version))
      redirect_to(marketing_engagement_path(@engagement), notice: 'Code record updated; previous merchant verification cleared.')
    end

    def verify
      raise ReplyWorkflow::Invalid, 'Confirm that you checked the merchant code and all terms.' unless params[:confirmed] == '1'

      InfluencerOfferWriter.write(@engagement.offers.find(params[:id]), actor: Current.user, attributes: {}, version: params[:lock_version], verify: true)
      redirect_to(marketing_engagement_path(@engagement), notice: 'Merchant evidence confirmed for 24 hours.')
    end

    def copy
      @copy = InfluencerOfferWriter.copy(@engagement.offers.find(params[:id]), actor: Current.user)
      @back_url = marketing_engagement_path(@engagement)
      render('marketing/cms/copy')
    end

    private

    def set_engagement
      @engagement = Engagement.find(params[:engagement_id])
    end

    def attributes
      params.require(:cms_record).permit(*InfluencerOfferWriter::FIELDS).to_h.symbolize_keys
    end

    def prepare_form
      @form_url = @record.persisted? ? marketing_engagement_offer_path(@engagement, @record) : marketing_engagement_offers_path(@engagement)
      @back_url = marketing_engagement_path(@engagement)
      render('marketing/cms/form')
    end
  end
end
