# frozen_string_literal: true

module Marketing
  class CampaignsController < RecordsController
    private

    def model = Campaign
    def fields = %i[name storefront_url topics]
  end
end
