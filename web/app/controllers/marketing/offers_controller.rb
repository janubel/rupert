# frozen_string_literal: true

module Marketing
  class OffersController < RecordsController
    def verify
      authorize_review
      offer = Offer.find(params[:id])
      raise ReplyWorkflow::Invalid, 'Confirm that the current merchant code and all terms match.' unless params[:confirmed] == '1'
      raise ReplyWorkflow::Invalid, 'Record a merchant evidence URL first.' if offer.evidence_url.blank?

      offer.update!(lock_version: params.require(:lock_version), verified_at: Time.current, verified_by_id: Current.user.id)
      ActivityLogger.log('marketing.offer_verified', subject: offer, details: { code: offer.code, evidence_url: offer.evidence_url })
      redirect_to(marketing_path, notice: 'Merchant evidence confirmed for 24 hours. No merchant data was changed.')
    end

    private

    def model = Offer
    def fields = %i[community_id code terms destination_url starts_at ends_at evidence_url]
  end
end
