# frozen_string_literal: true

module Marketing
  class InteractionsController < BaseController
    def create
      influencer = Influencer.find(params[:influencer_id])
      attributes = params.require(:interaction).permit(:kind, :body, :occurred_at).to_h.symbolize_keys
      CmsWriter.log_interaction(influencer, attributes: attributes, actor: Current.user)
      redirect_to(marketing_influencer_path(influencer), notice: 'Interaction recorded. No message was sent.')
    end
  end
end
