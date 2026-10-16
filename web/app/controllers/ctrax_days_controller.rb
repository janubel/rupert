# frozen_string_literal: true

require 'csv'

class CtraxDaysController < AuthenticatedController
  before_action do
    authorize(:module, :sales_read?)
    response.headers['Cache-Control'] = 'no-store'
  end

  def index
    @date = params[:date].present? ? Date.iso8601(params[:date]) : Time.current.in_time_zone('America/New_York').to_date
    @days = CtraxDay.includes(:location).where(business_date: @date).order(:location_id)
    @connection = PosConnection.find_by(provider: 'ctrax')
  rescue Date::Error
    redirect_to ctrax_days_path, alert: 'Choose a valid business date.'
  end

  def show
    @day = CtraxDay.find(params[:id])
    @reconciliation = Ctrax::Reconciliation.new(@day)
    respond_to do |format|
      format.html
      format.csv do
        data = CSV.generate do |csv|
          csv << %w[BusinessDate Store Currency Check Unit Detail Source Difference]
          @reconciliation.checks.each do |check|
            csv << [@day.business_date, @day.store_id, @day.currency, check[:label], check[:monetary] ? 'minor_units' : 'count', check[:actual], check[:expected], check[:delta]]
          end
        end
        send_data data, filename: "ctrax-#{@day.business_date}-#{@day.store_id}.csv", type: 'text/csv'
      end
    end
  end

  def create
    return head(:forbidden) unless Current.user.can?('sales.write') && Current.user.can?('sync.write')

    connection = PosConnection.find_by!(provider: 'ctrax', vendor_approved: true)
    date = Date.iso8601(params[:date].to_s)
    CtraxSalesSyncJob.perform_later(connection.id, date: date.iso8601, manual: true)
    redirect_to ctrax_days_path(date: date.iso8601), notice: 'C-Trax daily sales and register read queued.'
  rescue Date::Error
    redirect_to ctrax_days_path, alert: 'Choose a valid business date.'
  end

  def review
    return head(:forbidden) unless Current.user.can?('sales.write')

    day = CtraxDay.find(params[:id])
    day.with_lock do
      if day.source_digest != params[:source_digest]
        return redirect_to ctrax_day_path(day), alert: 'Source data changed. Review the current import first.'
      end
      if !Ctrax::Reconciliation.new(day).matched? && params[:note].to_s.strip.blank?
        return redirect_to ctrax_day_path(day), alert: 'Add a note for unresolved differences.'
      end
      day.update!(reviewed_by: Current.user, reviewed_at: Time.current, reviewed_digest: day.source_digest, review_note: params[:note].to_s.first(1000))
      ActivityLogger.log('ctrax_day_reviewed', subject: day, details: "#{day.business_date} digest #{day.source_digest}")
    end
    redirect_to ctrax_day_path(day), notice: 'Local review recorded. Source records and deposits were not changed.'
  end
end
