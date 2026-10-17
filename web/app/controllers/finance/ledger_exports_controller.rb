# frozen_string_literal: true

module Finance
  # Downloads the posted general ledger in an importable format (roadmap F40).
  # The form picks a date range and format; the download is read-only.
  class LedgerExportsController < AuthenticatedController
    before_action -> { authorize(:module, :finance_read?) }

    def new
      @from = parse_date(params[:from]) || Date.current.beginning_of_month
      @to = parse_date(params[:to]) || Date.current
      @format = Finance::LedgerExport::FORMATS.first.key
    end

    def create
      from = parse_date(params[:from]) || Date.current.beginning_of_month
      to = parse_date(params[:to]) || Date.current
      export = Finance::LedgerExport.new(from: from, to: to)
      format = export.format_for(params[:format])
      send_data export.render(format.key),
        filename: export.filename(format.key),
        type: format.content_type,
        disposition: 'attachment'
    end

    private

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
