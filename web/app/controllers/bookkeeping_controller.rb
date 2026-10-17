# frozen_string_literal: true

class BookkeepingController < AuthenticatedController
  before_action -> { authorize(:module, :finance_read?) }
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def show
    @overview = BookkeepingOverview.new(month: params[:month], account: params[:account])
  rescue BookkeepingOverview::Error => e
    redirect_to bookkeeping_path, alert: e.message
  end
end
