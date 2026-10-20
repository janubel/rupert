# frozen_string_literal: true

class Tenant < ApplicationRecord
  self.table_name = 'tenants'
  self.primary_key = 'id'

  has_many :users, dependent: :destroy
  has_many :settings, dependent: :destroy
  has_many :api_access_tokens, dependent: :destroy

  before_create :generate_id

  validates :name, presence: true
  validates :subdomain, length: { maximum: 63 }
  validates :name, length: { maximum: 160 }
  validates :subdomain,
    presence: true,
    uniqueness: true,
    format: { with: /\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/,
              message: 'must be lowercase letters, numbers, and hyphens' }
  validates :shopify_shop_domain,
    allow_blank: true,
    format: { with: /\A[a-z0-9-]+\.myshopify\.com\z/, message: 'must look like your-store.myshopify.com' }

  def to_param
    subdomain
  end

  private

  def generate_id
    self.id ||= SecureRandom.uuid
  end
end
