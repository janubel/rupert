# frozen_string_literal: true

module Api
  module V1
    class RoadmapController < BaseController
      def index
        return unless require_scope('roadmap:read')

        render json: { data: JSON.parse(Rails.root.join('config/product_roadmap.json').read), meta: { api_version: 'v1' } }
      end
    end
  end
end
