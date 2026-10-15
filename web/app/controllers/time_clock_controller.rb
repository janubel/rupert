# frozen_string_literal: true

class TimeClockController < AuthenticatedController
  before_action :active_context
  before_action :authorize_reviewer, only: %i[approve_correction reject_correction]
  rescue_from TimeClockService::Error, ActiveRecord::RecordInvalid, with: :clock_error
  rescue_from ActiveRecord::StatementInvalid, with: :database_error

  def index
    @worker = TimeClockService.worker_for(Current.user)
    @open_shift = ClockShift.open.find_by(user_id: Current.user.id)
    @pagy, @shifts = pagy(ClockShift.where(user_id: Current.user.id).recent.includes(:corrections), items: 30)
    if Current.user.can?('payroll.write')
      @pending_corrections = ClockCorrection.where(status: 'pending').includes(:clock_shift).order(:created_at).limit(100)
    end
  end

  def clock_in
    TimeClockService.clock_in(user: Current.user, request_token: params[:request_token].to_s)
    redirect_to time_clock_path, notice: 'Clock-in recorded.'
  end

  def clock_out
    TimeClockService.clock_out(user: Current.user, shift_id: params[:shift_id])
    redirect_to time_clock_path, notice: 'Clock-out recorded.'
  end

  def request_correction
    TimeClockService.request_correction(user: Current.user, shift_id: params[:id],
      attributes: params.require(:clock_correction).permit(:proposed_started_at, :proposed_ended_at, :reason).to_h.symbolize_keys)
    redirect_to time_clock_path, notice: 'Correction requested. Your shift stays unchanged until review.'
  end

  def approve_correction
    TimeClockService.review(correction: ClockCorrection.find(params[:id]), reviewer: Current.user, approve: true)
    redirect_to time_clock_path, notice: 'Correction approved and audited.'
  end

  def reject_correction
    TimeClockService.review(correction: ClockCorrection.find(params[:id]), reviewer: Current.user, approve: false)
    redirect_to time_clock_path, notice: 'Correction rejected; shift times are unchanged.'
  end

  def commissions
    authorize(:module, :payroll_read?)
    @start_date = params[:start_date].presence || 6.days.ago.to_date.iso8601
    @end_date = params[:end_date].presence || Date.current.iso8601
    @source = params[:source].presence || 'shopify'
    @currency = params[:currency].presence || 'USD'
    @preview = CommissionPreview.new(start_date: @start_date, end_date: @end_date, source: @source, currency: @currency)
  rescue CommissionPreview::Error => e
    @preview_error = e.message
    render :commissions, status: :unprocessable_entity
  end

  private

  def active_context
    return if Current.user.active? && Current.tenant&.status == 'active'

    redirect_to root_path, alert: 'An active sign-in account and store are required.'
  end

  def authorize_reviewer
    authorize(:module, :payroll_write?)
  end

  def clock_error(error)
    message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
    redirect_to time_clock_path, alert: message
  end

  def database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    redirect_to time_clock_path, alert: 'The time clock is busy. Retry your request; it is safe to retry the same clock-in/out.'
  end
end
