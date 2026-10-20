# frozen_string_literal: true

require 'bigdecimal'

# A secret warehouse-sale link shared with a vendor. The token in the URL is
# the only access control — it is never listed in the app's navigation.
class WarehouseShare < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'WarehouseShare'
  self.primary_key = 'id'

  # The legacy schema uses camelCase columns while Rails conventions (and the
  # TenantScoped concern) rely on snake_case attribute names.
  alias_attribute :tenant_id, :tenantId
  alias_attribute :use_custom_tiers, :useCustomTiers

  # TenantScoped's belongs_to :tenant assumes a tenant_id column; the physical
  # column here is tenantId, so re-declare with the explicit foreign key.
  belongs_to :tenant, optional: true, foreign_key: :tenantId

  has_many :tiers,
    class_name: 'WarehouseTier',
    foreign_key: 'shareId',
    dependent: :destroy

  before_validation :generate_token, on: :create
  before_validation :set_default_expiry, on: :create

  validates :name, presence: true
  validates :token, presence: true, uniqueness: true
  validates :priceMultiplier, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(status: 'active').where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :recent, ->(limit = 50) { order(createdAt: :desc).limit(limit) }

  DEFAULT_WINDOW = 30.days

  def to_param
    token
  end

  def active?
    status == 'active' && !expired?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Bulk tier schedule: per-vendor tiers when custom, otherwise the global
  # defaults (this share's tenant's WarehouseTier rows with a nil shareId).
  # Explicitly keyed by the share's tenant so it never depends on Current.tenant.
  def effective_tiers
    (use_custom_tiers? ? tiers : WarehouseTier.unscoped.where(tenantId: tenantId, shareId: nil)).order(:minQty)
  end

  def tier_for(qty)
    effective_tiers.select { |t| qty.to_i >= t.minQty }.max_by(&:minQty)
  end

  def discount_for(qty)
    BigDecimal(tier_for(qty)&.discountPercent.to_s.presence || '0')
  end

  # Per-vendor price before bulk discount (list price × vendor multiplier).
  # Decimal arithmetic: list prices come from a float column, so they are
  # re-read through their shortest decimal representation first.
  def unit_price(list_price)
    BigDecimal(list_price.to_s.presence || '0') * BigDecimal(priceMultiplier.to_s.presence || '1')
  end

  def sale_price(list_price, qty)
    (unit_price(list_price) * (1 - discount_for(qty) / 100)).round(2)
  end

  private

  def generate_token
    self.token ||= SecureRandom.alphanumeric(32)
  end

  def set_default_expiry
    self.expires_at ||= DEFAULT_WINDOW.from_now
  end
end
