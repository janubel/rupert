# frozen_string_literal: true

module Api
  module V1
    class CatalogController < BaseController
      def index
        return unless require_scope('catalog:read')

        source = params.fetch(:source, 'shopify').to_s
        unless %w[shopify square].include?(source)
          render json: { error: { code: 'invalid_source', message: 'source must be shopify or square.' } }, status: :bad_request
          return
        end
        scope = source == 'shopify' ? ShopifyVariant.order(:id) : SquareVariation.order(:id)
        render_page(scope, meta: { source: source }) do |item|
          {
            id: item.id, source: source, sku: item.sku,
            name: source == 'shopify' ? item.title : item.name,
            product_id: source == 'shopify' ? item.productId : item.itemId,
            price: source == 'shopify' ? item.price : nil
          }
        end
      end
    end
  end
end
