# frozen_string_literal: true

require 'date'
require 'time'

class BulkRecipeService
  def self.create(source_variant_id:, material_id:, grams_per_unit:, effective_from:, actor:)
    raise ActiveRecord::RecordNotFound if Current.tenant_id.blank?

    material = BulkMaterial.find(material_id)
    variant = ShopifyVariant.find_by(id: source_variant_id)
    recipe = BulkRecipe.new(tenant_id: Current.tenant_id, source: 'shopify', source_variant_id: source_variant_id,
      bulk_material: material, created_by: actor, grams_per_unit: grams_per_unit,
      catalog_title: [variant&.product&.title, variant&.title].compact.join(' — ').truncate(500, omission: ''), catalog_sku: variant&.sku,
      definition_checked: true)
    unless variant&.product && variant.tenant_id == Current.tenant_id && variant.product.tenant_id == Current.tenant_id
      recipe.errors.add(:source_variant_id, 'must identify an exact Shopify variant in this store')
      return recipe
    end
    begin
      text = grams_per_unit.to_s.strip
      raise ArgumentError unless text.length <= 40 && text.match?(/\A[0-9]+(?:\.[0-9]{1,3})?\z/)

      recipe.mg_per_unit = BulkMass.convert(text, 'g').first
    rescue ArgumentError
      recipe.errors.add(:grams_per_unit, 'must be positive grams with at most three decimal places within the supported range')
      return recipe
    end
    begin
      recipe.effective_from = parse_effective_time(effective_from)
    rescue ArgumentError
      recipe.errors.add(:effective_from, 'must be a valid time with an explicit UTC offset')
      return recipe
    end

    BulkRecipe.transaction do
      locked = Tenant.unscoped.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      raise ActiveRecord::RecordNotFound unless locked == 1

      previous = BulkRecipe.where(source: 'shopify', source_variant_id: source_variant_id).order(version: :desc).first
      if previous && recipe.effective_from <= previous.effective_from
        recipe.errors.add(:effective_from, 'must be later than the preceding recipe version')
        return recipe
      end
      recipe.version = previous ? previous.version + 1 : 1
      recipe.save
    end
    recipe
  end

  def self.parse_effective_time(value)
    if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      raise ArgumentError if value.utc_offset.abs > 14 * 3600

      return value
    end
    unless value.is_a?(String) && value.length <= 100 && !value.end_with?('-00:00') &&
        value.match?(/\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})\z/)
      raise ArgumentError
    end

    date = DateTime.iso8601(value)
    raise ArgumentError if date.offset.abs > Rational(14, 24)
    Time.iso8601(value)
  end
  private_class_method :parse_effective_time
end
