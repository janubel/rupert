# frozen_string_literal: true

class InventoryCountsController < AuthenticatedController
  before_action :require_inventory_read
  before_action :require_inventory_write, except: %i[index show]

  def index
    @counts = InventoryCount.by_status(params[:status]).recent(30)
  end

  def show
    @count = InventoryCount.includes(items: { shopify_variant: :product }).find(params[:id])
  end

  def new
    @count = InventoryCount.new(countedAt: Time.current, locationId: params[:location_id])
    @locations = Location.order(name: :asc).limit(200)
    @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
    @prepared = params[:prepared] != '0'

    if @prepared
      @count.items = prepared_sheet_items
    else
      @count.items.build
    end
  end

  def create
    @count = InventoryCount.new(count_params.merge(createdBy: Current.user.email))
    build_items(@count)
    if @count.save
      destination = params[:start_scanning] == '1' ? scan_inventory_count_path(@count) : inventory_count_path(@count)
      redirect_to(destination, notice: 'Draft count created.')
    else
      prepare_form
      @prepared = false
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    @count = InventoryCount.includes(items: { shopify_variant: :product }).find(params[:id])
    return unless require_draft

    prepare_form
  end

  def update
    @count = InventoryCount.find(params[:id])
    @count.with_lock do
      return unless require_draft

      @count.assign_attributes(count_params)
      @count.items.destroy_all
      build_items(@count)
      @count.save!
    end
    redirect_to(inventory_count_path(@count), notice: 'Count updated.')
  rescue ActiveRecord::RecordInvalid
    prepare_form
    render(:edit, status: :unprocessable_entity)
  end

  def submit
    @count = InventoryCount.find(params[:id])
    @count.with_lock do
      return unless require_draft

      @count.snapshot_previous!
      @count.submit!
    end
    BuzzNotifyJob.perform_later(
      "Manual count submitted for approval · #{@count.items.count} items · total qty #{@count.total_quantity}",
      tags: [%w[t inventory]]
    )
    redirect_to(inventory_count_path(@count), notice: 'Count submitted for approval.')
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: 'Only draft counts can be submitted.')
  end

  def approve
    @count = InventoryCount.find(params[:id])
    @count.with_lock do
      @count.approve!
      @count.apply_override!(actor: Current.user.email)
      @count.update!(approvedAt: Time.current)
    end
    DataCache.bump!
    redirect_to(inventory_count_path(@count),
      notice: 'Count approved and recorded — overrides are disabled (Square is the source of truth).')
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: 'Only pending counts can be approved.')
  rescue StandardError => e
    redirect_to(inventory_count_path(@count), alert: "Approval failed: #{e.message}")
  end

  def reject
    @count = InventoryCount.find(params[:id])
    @count.with_lock { @count.reject! }
    redirect_to(inventory_count_path(@count), notice: 'Count rejected.')
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: 'Only pending counts can be rejected.')
  end

  def reopen
    @count = InventoryCount.find(params[:id])
    @count.with_lock { @count.reopen! }
    redirect_to(inventory_count_path(@count), notice: 'Count reopened as a draft — edit and resubmit it.')
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: 'Only rejected counts can be reopened.')
  end

  def destroy
    @count = InventoryCount.find(params[:id])
    @count.with_lock do
      return unless require_draft

      @count.destroy!
    end
    redirect_to(inventory_counts_path, notice: 'Draft deleted.')
  end

  private

  def require_inventory_read
    return if Current.user.can?('inventory.read')

    redirect_to root_path, alert: "You don't have permission to view inventory counts."
  end

  def require_draft
    return true if @count.draft?

    redirect_to inventory_count_path(@count), alert: 'Only draft counts can be changed.'
    false
  end

  def prepare_form
    @locations = Location.order(name: :asc).limit(200)
    @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
  end

  def require_inventory_write
    return if Current.user.can?('inventory.write')

    redirect_to(inventory_counts_path, alert: "You don't have permission to modify inventory counts.")
  end

  def count_params
    params.require(:inventory_count).permit(:locationId, :note, :countedAt)
  end

  # A "prepared sheet": every SKU with a Shopify variant and its current system
  # total, so a counter only has to fill in the manual override column (what's
  # actually on hand) and submit the whole sheet at once. Includes SKUs that
  # aren't yet linked to Square so the sheet is complete.
  def prepared_sheet_items
    links = SkuLink.includes(shopify_variant: :product).order(:sku).to_a
    totals = InventoryLevel.where(shopifyVariantId: links.map(&:shopifyVariantId).compact)
                           .group(:shopifyVariantId).sum(:quantity)

    links.filter_map do |link|
      variant = link.shopify_variant
      next if variant.nil?

      InventoryCountItem.new(
        sku: link.sku,
        shopifyVariantId: link.shopifyVariantId,
        squareVariationId: link.squareVariationId,
        quantity: totals[link.shopifyVariantId].to_i
      )
    end
  end

  def build_items(count)
    rows = params[:items].is_a?(ActionController::Parameters) ? params[:items].values : Array(params[:items])
    rows.each do |row|
      next unless row.respond_to?(:permit)

      sku = row[:sku].to_s.strip
      next if sku.blank? && row[:quantity].to_s.blank?

      count.items.build(sku: sku, quantity: row[:quantity])
    end
  end
end
