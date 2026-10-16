# frozen_string_literal: true

class ShopifyProduct < ApplicationRecord
  include TenantScoped

  self.table_name = 'ShopifyProduct'
  self.primary_key = 'id'

  has_many :variants,
    class_name: 'ShopifyVariant',
    foreign_key: 'productId',
    dependent: :destroy,
    inverse_of: :product

  scope :active, -> { where(status: 'ACTIVE', catalog_present: [nil, true]) }
  scope :search, lambda { |q|
    return all if q.blank?

    where(title: q).or(where('title LIKE ?', "%#{q}%"))
  }

  # Shopify CDN URLs accept &width= / &height= to request resized renditions.
  # Returns a compact thumbnail URL when a featured image exists.
  def thumbnail_url(width: 96, height: 96)
    return if featuredImageUrl.blank?

    separator = featuredImageUrl.include?('?') ? '&' : '?'
    "#{featuredImageUrl}#{separator}width=#{width}&height=#{height}"
  end
end
