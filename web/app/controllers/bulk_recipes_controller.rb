# frozen_string_literal: true

class BulkRecipesController < BulkInventoryController
  def index
    @pagy, @recipes = pagy(:offset, BulkRecipe.includes(:bulk_material).order(created_at: :desc, id: :desc), limit: 30)
  end

  def new
    @recipe = BulkRecipe.new(source_variant_id: params[:source_variant_id], effective_from: Time.current)
    load_options
  end

  def create
    submitted = params.require(:bulk_recipe).permit(:source_variant_id, :material_id, :grams_per_unit, :effective_from)
    @submitted_effective_from = submitted[:effective_from].to_s.first(200)
    @recipe = BulkRecipeService.create(**submitted.to_h.symbolize_keys, actor: Current.user.email)
    if @recipe.persisted?
      redirect_to(bulk_recipes_path, notice: 'Recipe version recorded for this exact variant. No stock was deducted.')
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  rescue ArgumentError
    redirect_to(new_bulk_recipe_path, alert: 'Choose an exact catalog variant, material, positive grams and an effective time.')
  end

  private

  def load_options
    @query = params[:q].to_s.strip.first(200)
    variants = ShopifyVariant.includes(:product).where(productId: ShopifyProduct.select(:id))
    if @query.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%"
      products = ShopifyProduct.where('LOWER(title) LIKE ?', term).select(:id)
      variants = variants.where('LOWER(sku) LIKE ? OR LOWER(title) LIKE ? OR "productId" IN (?)', term, term, products)
    end
    @variants = variants.order(:sku, :id).limit(51).to_a
    @variants_limited = @variants.length > 50
    @variants = @variants.first(50)
    selected = ShopifyVariant.includes(:product).find_by(id: @recipe.source_variant_id)
    @variants.unshift(selected) if selected && @variants.none? { |variant| variant.id == selected.id }
    @materials = BulkMaterial.order(:name, :id).limit(201).to_a
    @materials_limited = @materials.length > 200
    @materials = @materials.first(200)
  end
end
