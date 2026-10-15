# frozen_string_literal: true

module Api
  module V1
    class InventoryController < BaseController
      def index
        return unless require_scope('inventory:read')

        source = params[:source].presence
        if source && !%w[shopify square].include?(source)
          render json: { error: { code: 'invalid_source', message: 'source must be shopify or square.' } }, status: :bad_request
          return
        end
        scope = InventoryLevel.where(source: %w[shopify square]).order(:id)
        scope = scope.where(source: source) if source
        scope = scope.where(locationId: params[:location_id]) if params[:location_id].present?
        render_page(scope, meta: { quantities: 'Independent mirrored platform/location stock; no cross-channel equalization.' }) do |level|
          {
            id: level.id, source: level.source, location_id: level.locationId,
            item_id: level.source == 'shopify' ? level.shopifyVariantId : level.squareVariationId,
            quantity: level.quantity, available: level.available, updated_at: level.updatedAt
          }
        end
      end
    end
  end
end
