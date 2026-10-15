# frozen_string_literal: true

# Size families: group a base-gram product's multiple sizes so their inventory
# is derived from the family's root gram bank instead of Square realtime.
class SizeFamiliesController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_manage,
    except: %i[index derive derive_all approve_all approve]
  before_action :authorize_apply, only: %i[derive derive_all approve_all approve]
  before_action :set_family,
    only: %i[edit update destroy derive set_root approve_all add_member remove_member approve]

  def index
    @families = SizeFamilySnapshot.all.map do |snap|
      {
        family: snap.family,
        root: snap.root_grams,
        members: snap.members,
        pending_count: snap.pending_count,
        last_derived: snap.last_derived
      }
    end
    @pending_changes = SizeChange.pending.order(:sku).to_a
  end

  def new
    @family = SizeFamily.new
  end

  def create
    @family = SizeFamily.new(family_params)
    @family.tenant_id = Current.tenant_id
    if @family.save
      redirect_to(size_families_path, notice: 'Size family created — add its sizes next.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit; end

  def update
    if @family.update(family_params)
      redirect_to(size_families_path, notice: 'Size family updated.')
    else
      render(:edit, status: :unprocessable_entity)
    end
  end

  def destroy
    @family.destroy
    redirect_to(size_families_path, notice: 'Size family removed.')
  end

  # POST /size_families/:id/derive — recompute sizes from the root gram bank now.
  def derive
    summary = SizeDeriver.process(@family)
    redirect_to(
      size_families_path,
      notice: "Derived #{@family.name}: root #{summary[:build][:root_grams]}g, " \
              "#{summary[:pending]} pending, #{summary[:applied]} applied, #{summary[:failed]} failed."
    )
  rescue StandardError => e
    redirect_to(size_families_path, alert: "Derivation failed for #{@family.name}: #{e.message}")
  end

  # POST /size_families/derive_all — recompute every family now.
  def derive_all
    summary = SizeDeriver.process_all!
    redirect_to(
      size_families_path,
      notice: "Derived #{summary[:families]} families: #{summary[:pending]} pending, " \
              "#{summary[:applied]} applied, #{summary[:failed]} failed."
    )
  end

  # POST /size_families/:id/set_root — manual override of the root gram bank.
  def set_root
    grams = params[:base_grams].to_f
    @family.update!(base_grams: grams, sales_watermark: Time.current)
    redirect_to(size_families_path,
      notice: "Root for #{@family.name} set to #{grams}g — sales from now on will fold in.")
  end

  # POST /size_families/approve_all (collection) or /size_families/:id/approve_all
  # (member) — write pending sizes to Square, for one family or all.
  def approve_all
    Current.confirm_push! # UI actions already require an explicit confirm dialog
    scope = @family ? @family.size_changes.pending : SizeChange.pending
    applied = 0
    failed = 0
    scope.find_each do |change|
      SizeDeriver.apply_change!(change) ? applied += 1 : failed += 1
    end
    target = @family ? @family.name : 'all families'
    redirect_to(size_families_path, notice: "Approved sizes for #{target}: #{applied} applied, #{failed} failed.")
  end

  # POST /size_families/:id/approve — write one pending size to Square.
  def approve
    Current.confirm_push! # UI actions already require an explicit confirm dialog
    change = @family.size_changes.find(params[:change_id])
    ok = SizeDeriver.apply_change!(change)
    redirect_to(
      size_families_path,
      ok ? { notice: "Applied #{change.sku} → #{change.target_quantity}." } : { alert: "Failed #{change.sku}: #{change.error}" }
    )
  end

  # POST /size_families/:id/add_member — add a size (sku + grams) to a family.
  def add_member
    member = @family.members.new(sku: params[:sku].to_s.strip, grams: params[:grams])
    member.tenant_id = Current.tenant_id
    if member.save
      redirect_to(edit_size_family_path(@family), notice: "Added #{member.sku} (#{member.grams}g).")
    else
      redirect_to(edit_size_family_path(@family), alert: member.errors.full_messages.to_sentence)
    end
  end

  # POST /size_families/:id/remove_member — drop a size from a family.
  def remove_member
    member = @family.members.find(params[:member_id])
    member.destroy
    redirect_to(edit_size_family_path(@family), notice: "Removed #{member.sku}.")
  end

  private

  def set_family
    # Collection routes (e.g. approve_all) carry no :id — the action handles a
    # nil @family (all families). Member routes always pass :id.
    @family = SizeFamily.find(params[:id]) if params[:id].present?
  end

  def family_params
    params.require(:size_family).permit(:name, :root_sku, :mode)
  end

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_manage
    authorize(:module, :settings_write?)
  end

  def authorize_apply
    authorize(:module, :reconcile_write?)
  end
end
