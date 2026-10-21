# frozen_string_literal: true

# SwipeSimple daily close: stored export totals, checks and a local review for
# one America/New_York business day. Read-only toward SwipeSimple and NAB.
class SwipesimpleDaysController < AuthenticatedController
  before_action do
    authorize(:module, :sales_read?)
    response.headers['Cache-Control'] = 'no-store'
  end

  def index
    @date = params[:date].present? ? Date.iso8601(params[:date].to_s) : Time.current.in_time_zone(SwipesimpleDayClose::ZONE).to_date
    @close = SwipesimpleDayClose.new(@date)
    respond_to do |format|
      format.html
      format.csv do
        log_export('SwipeSimple daily close', @date.iso8601)
        send_data @close.to_csv, filename: "swipesimple-#{@date.iso8601}.csv", type: 'text/csv'
      end
    end
  rescue Date::Error
    redirect_to swipesimple_days_path, alert: 'Choose a valid business date.'
  end

  # Owner choice of the NAB merchant whose deposits fund SwipeSimple card
  # sales. The form carries an opaque token, never the merchant number.
  def deposit_merchant
    return head(:forbidden) unless Current.user.can?('settings.write')

    back = swipesimple_days_path(date: params[:date].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? params[:date] : nil, anchor: 'close-deposit')
    token = params[:merchant_token].to_s
    merchant = SwipesimpleDayClose.deposit_merchants.find { |candidate| SwipesimpleDayClose.merchant_token(candidate) == token }
    return redirect_to(back, alert: 'Choose a NAB merchant from the list.') if token.present? && merchant.nil?

    TenantSettings.set(:swipesimple_deposit_merchant, merchant.to_s)
    label = merchant ? SwipesimpleDayClose.mask(merchant) : 'none'
    ActivityLogger.log('swipesimple_deposit_merchant_set', details: "NAB merchant #{label}")
    redirect_to back, notice: merchant ? "SwipeSimple card sales are now compared with NAB merchant #{label} deposits." : 'Deposit merchant cleared.'
  end

  def review
    return head(:forbidden) unless Current.user.can?('sales.write')

    date = Date.iso8601(params[:date].to_s)
    close = SwipesimpleDayClose.new(date)
    note = params[:note].to_s.strip.first(1000)
    if close.source_digest != params[:source_digest]
      return redirect_to swipesimple_days_path(date: date), alert: 'The SwipeSimple export changed. Review the current data first.'
    end
    if close.warnings.any? && note.blank?
      return redirect_to swipesimple_days_path(date: date, anchor: 'close-review'), alert: 'Add a note for the flagged checks.'
    end

    SwipesimpleDayReview.transaction do
      review = SwipesimpleDayReview.lock.find_or_initialize_by(business_date: date)
      review.update!(reviewed_by: Current.user, reviewed_at: Time.current, reviewed_digest: close.source_digest, review_note: note.presence)
      ActivityLogger.log('swipesimple_day_reviewed', subject: review, details: "#{date} digest #{close.source_digest.first(12)}")
    end
    redirect_to swipesimple_days_path(date: date), notice: 'Local review recorded. Nothing was changed at SwipeSimple or NAB.'
  rescue ActiveRecord::RecordNotUnique
    redirect_to swipesimple_days_path(date: date), alert: 'Someone else recorded a review at the same time. Check it and try again.'
  rescue Date::Error
    redirect_to swipesimple_days_path, alert: 'Choose a valid business date.'
  end
end
