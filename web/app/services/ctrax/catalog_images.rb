# frozen_string_literal: true

module Ctrax
  class CatalogImages
    attr_reader :products

    def initialize(location)
      @products = ShopifyProduct.active.where.not(featuredImageUrl: [nil, '']).includes(:variants).to_a
      @manual = CtraxImageLink.where(location: location).index_by(&:variant_id)
      @ids = @products.index_by { |product| native_id(product.id) }
      @titles = @products.group_by { |product| normalized(product.title) }
      @skus = @products.flat_map { |product| product.variants.map { |v| [v.sku, product] } }
        .reject { |sku, _product| sku.blank? }.group_by(&:first)
    end

    def product_for(record)
      manual = @manual[record['id']]&.shopify_product
      return manual if manual && manual.tenant_id == Current.tenant_id

      exact = @ids[native_id(record['website_product_id'])] if record['website_product_id'].present?
      return exact if exact

      by_sku = @skus.fetch(record['sku'], []).map(&:last).uniq
      return by_sku.first if by_sku.size == 1

      matches = @titles.fetch(normalized(record['product_name'].presence || record['name']), [])
      matches.first if matches.size == 1
    end

    # size: the square thumbnail edge in pixels (the POS tile and item sheet ask for larger ones).
    def url(record, size = 320)
      product = product_for(record)
      return unless product && product.featuredImageUrl.present?

      uri = URI.parse(product.featuredImageUrl)
      return unless uri.scheme == 'https' && uri.userinfo.nil? && uri.port == 443 &&
                    (uri.host == 'cdn.shopify.com' || uri.host == 'herbalhealerscbd.com' || uri.host == 'www.herbalhealerscbd.com' || uri.host == 'herbalhealers.com' || uri.host == 'www.herbalhealers.com')

      product.thumbnail_url(width: size, height: size)
    rescue URI::InvalidURIError
      nil
    end

    private

    def native_id(value)
      value.to_s.split('/').last
    end

    def normalized(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^[:alnum:]]+/, ' ').strip
    end
  end
end
