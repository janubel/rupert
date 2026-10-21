# frozen_string_literal: true

module Finance
  # Cash flow dashboard: bank movement, sales, spend and position for a date
  # range, with a JSON twin the page polls to stay current.
  class CashFlowController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }
    before_action { response.headers['Cache-Control'] = 'private, no-store' }

    def show
      @report = CashFlowReport.from_params(params)
      respond_to do |format|
        format.html
        format.turbo_stream { render turbo_stream: live_streams }
        format.json { render json: @report.to_h }
      end
    rescue CashFlowReport::Error => e
      respond_to do |format|
        format.html { redirect_to finance_cash_flow_path, alert: e.message }
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
      end
    end

    private

    # The page polls itself and swaps these regions in place; the charts read the
    # refreshed data block and redraw without a flash.
    LIVE_PARTIALS = %w[meta kpis data bank_table channels_table spend deposits position events].freeze

    def live_streams
      LIVE_PARTIALS.map { |name| turbo_stream.replace("cash-flow-#{name.tr('_', '-')}", partial: "finance/cash_flow/#{name}", locals: { report: @report }) }
    end
  end
end
