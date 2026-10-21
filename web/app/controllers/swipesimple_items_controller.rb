# frozen_string_literal: true

# SwipeSimple item list: import SwipeSimple's item export, then see each item
# next to the same item in Shopify, Square and C-Trax. Read-only toward every
# platform; an import only replaces Rupert's stored SwipeSimple snapshot.
class SwipesimpleItemsController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action -> { redirect_to(root_path, alert: 'Inventory read permission is required.') unless Current.user.can?('inventory.read') }
  before_action -> { redirect_to(swipesimple_items_path, alert: 'Inventory write permission is required to import.') unless Current.user.can?('inventory.write') }, only: :create

  def index
    @snapshots = SwipesimpleItemSnapshot.order(:merchant_account).to_a
    @snapshot = @snapshots.find { |s| s.id.to_s == params[:snapshot_id].to_s } || @snapshots.max_by(&:captured_at)
    @default_account = @snapshot&.merchant_account || SwipesimpleExport.distinct.pluck(:merchant_account).first
    @match = SwipesimpleItemMatch.new(@snapshot) if @snapshot
    @status = SwipesimpleItemMatch::STATUSES.include?(params[:status]) ? params[:status] : nil
    respond_to do |format|
      format.html
      format.csv do
        return head(:not_found) unless @match

        log_export('SwipeSimple item match CSV', @snapshot.merchant_account)
        send_data(@match.csv, filename: "swipesimple-items-#{Date.current.iso8601}.csv", type: 'text/csv')
      end
    end
  end

  def create
    file = params[:file]
    return redirect_to(swipesimple_items_path, alert: 'Choose the CSV file exported from SwipeSimple.') unless file.respond_to?(:read)
    if file.size > SwipesimpleItemImporter::MAX_BYTES
      return redirect_to(swipesimple_items_path, alert: 'The file is larger than 5 MB.')
    end

    snapshot, preview = SwipesimpleItemImporter.import!(file.read, merchant_account: params[:merchant_account],
      filename: file.original_filename)
    ActivityLogger.log('swipesimple_items_imported', subject: snapshot, details: "#{snapshot.row_count} items for #{snapshot.merchant_account}")
    notice = "Imported #{snapshot.row_count} SwipeSimple items. Columns used: #{preview.mapped.map { |field, header| "#{field} ← #{header}" }.join(', ')}."
    notice += " #{preview.warnings.join(' ')}" if preview.warnings.any?
    redirect_to(swipesimple_items_path(snapshot_id: snapshot.id), notice: notice)
  rescue SwipesimpleItemImporter::Error => e
    redirect_to(swipesimple_items_path, alert: "Nothing was imported. #{e.message}")
  end
end
