# frozen_string_literal: true

# Product / variant detail: quantities on both sides, level breakdowns,
# movements, alerts, and the SKU link to a Square variation.
class ShopifyVariantsController < AuthenticatedController
  before_action :set_variant
  rescue_from ActiveRecord::StatementInvalid, with: :handle_mapping_database_error

  def show
    authorize(:module, :inventory_read?)
    @product = @variant.product
    @link = @variant.sku_links.linked.first
    @movements = @variant.movements.order(createdAt: :desc).limit(20)
    @alerts = @variant.alerts.order(createdAt: :desc).limit(10)
    @shopify_levels = @variant.levels.order(:locationId)
    @square_variations = searchable_square_variations
    @profile = ItemProfile.new(@variant)
  end

  # Manually link this Shopify variant to a Square variation (overrides any
  # auto link from sync).
  def link
    authorize(:module, :inventory_write?)
    square = nil
    CatalogMappingLock.synchronize do
      @variant = ShopifyVariant.find_by!(tenant_id: Current.tenant_id, id: @variant.id)
      square = SquareVariation.find_by!(tenant_id: Current.tenant_id, id: params[:square_variation_id])
      link = SkuLink.find_or_initialize_by(shopifyVariantId: @variant.id)
      link.tenant_id = Current.tenant_id
      link.squareVariationId = square.id
      link.sku = @variant.sku.presence || square.sku.presence || @variant.id
      link.matchSource = 'manual'
      link.auto = false
      link.createdAt ||= Time.current
      link.save!
      # An explicit identity decision wins over inferred claims by other rows.
      # Other deliberate mappings remain visible for shared-pool review.
      SkuLink.where(squareVariationId: square.id, auto: true, matchSource: 'sku')
        .where.not(shopifyVariantId: @variant.id).update_all(squareVariationId: nil)
    end
    DataCache.bump!
    redirect_to(shopify_variant_path(@variant), notice: "Linked #{@variant.title} to #{square.name}.")
  rescue ActiveRecord::RecordNotFound
    redirect_to(shopify_variant_path(@variant), alert: 'Square variation not found.')
  end

  # Persist the operator's decision so a later source sync cannot undo it.
  def unlink
    authorize(:module, :inventory_write?)
    CatalogMappingLock.synchronize do
      @variant = ShopifyVariant.find_by!(tenant_id: Current.tenant_id, id: @variant.id)
      link = SkuLink.find_or_initialize_by(shopifyVariantId: @variant.id)
      link.assign_attributes(tenant_id: Current.tenant_id, squareVariationId: nil,
        sku: @variant.sku.presence || @variant.id, matchSource: 'manual-unlink', auto: false)
      link.createdAt ||= Time.current
      link.save!
    end
    DataCache.bump!
    redirect_to(shopify_variant_path(@variant), notice: 'Explicitly unlinked. Automatic syncs will keep this item unlinked until you choose a new link.')
  end

  private

  def handle_mapping_database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause.class.name)

    redirect_to(shopify_variant_path(@variant), alert: 'Catalog mapping is busy. Review the current link before retrying.')
  end

  def set_variant
    @variant = ShopifyVariant.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  # Candidate Square variations to link against, preferring same-SKU matches.
  def searchable_square_variations
    scope = SquareVariation.where(tenant_id: Current.tenant_id)
    if @variant.sku.present?
      same_sku = scope.where(sku: @variant.sku).order(:name).limit(10)
      return same_sku if same_sku.any?

    end
    scope.order(:name).limit(20)
  end
end
