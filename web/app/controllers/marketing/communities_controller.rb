# frozen_string_literal: true

module Marketing
  class CommunitiesController < RecordsController
    def check_rules
      authorize_review
      community = Community.find(params[:id])
      community.update!(lock_version: params.require(:lock_version), rules_checked_at: Time.current)
      redirect_to(marketing_path, notice: 'Group promotion rules checked. This confirmation lasts 30 days.')
    end

    private

    def model = Community
    def fields = %i[campaign_id name url include_terms exclude_terms promotion_rules rules_url]
  end
end
