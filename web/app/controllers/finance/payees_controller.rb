# frozen_string_literal: true

require 'csv'

module Finance
  # Who the money went to: expenses and vendor payments grouped by payee, with
  # one payee's full history, matching bank lines and a CSV for the bookkeeper.
  class PayeesController < AuthenticatedController
    def index
      authorize(:module, :finance_read?)
      response.headers['Cache-Control'] = 'private, no-store'
      @range_days = params[:days].present? ? params[:days].to_i.clamp(7, 730) : 90
      @through = Date.current
      @from = @through - (@range_days - 1)
      @q = params[:q].to_s.strip
      @activity = Finance::PayeeActivity.new(from: @from, to: @through)
      @summaries = @activity.summaries
      @summaries = @summaries.select { |s| s.label.downcase.include?(@q.downcase) } if @q.present?
      @key = params[:key].to_s.presence
      @selected = @key && @activity.summary_for(@key)
      return head(:not_found) if request.format.csv? && !@selected
      return unless @selected

      @entries = @activity.entries_for(@key)
      respond_to do |format|
        format.html { @bank_lines = @activity.bank_lines_for(@selected.label) }
        format.csv { send_data payee_csv(@selected, @entries), filename: "payee-#{@selected.label.parameterize.presence || 'unlabelled'}-#{@range_days}d.csv" }
      end
    end

    private

    def payee_csv(summary, entries)
      CSV.generate do |csv|
        csv << ['Payee', summary.label, "#{@from} to #{@through}", 'Amounts in USD; expenses and vendor payments are separate records']
        csv << %w[Date Type Amount Category Method Reference]
        entries.each do |e|
          csv << [e.on, e.kind == :expense ? 'Expense' : 'Vendor payment', format('%.2f', e.cents / 100.0), e.category, e.method, safe(e.reference)]
        end
      end
    end

    def safe(value)
      text = value.to_s
      text.match?(/\A\s*[=+\-@]/) ? "'#{text}" : text
    end
  end
end
