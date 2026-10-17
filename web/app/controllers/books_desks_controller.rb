# frozen_string_literal: true

# The Books desk: the front door for the daily and weekly money cleanup. It
# shows each finished day as six ordered steps, the weekly chores and the one
# thing to do next, and links to the page that owns each action. Read-only.
class BooksDesksController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def show
    @desk = BooksDesk.new(week: params[:week])
    @findings = Finance::ReconciliationFindings.new
    @can_write_reports = Current.user.can?('reports.write')
    @can_write_finance = Current.user.can?('finance.write')
  rescue BooksDesk::Error, BooksPeriod::Error => e
    redirect_to books_desk_path, alert: e.message
  end

  # The housekeeping audit is the slowest part (it re-verifies retained
  # originals), so the desk loads it lazily into a frame after first paint.
  def checks
    @check = BooksCheck.new(window_days: 30)
    render partial: 'books_desks/checks', locals: { check: @check }
  end
end
