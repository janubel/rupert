# frozen_string_literal: true

# One-page, read-only audit of the money records: what is fine, what to watch
# and what to fix, each with the exact count and a link to the place to act.
class BooksCheckController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def show
    @check = BooksCheck.new(window_days: params[:days].presence || 30)
    respond_to do |format|
      format.html
      format.csv {
        log_export('Books check CSV', "#{@check.window_days} days")
        send_data(@check.csv, type: 'text/csv', filename: "books-check-#{Date.current.iso8601}.csv") }
    end
  end
end
