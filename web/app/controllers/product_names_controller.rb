# frozen_string_literal: true

class ProductNamesController < AuthenticatedController
  before_action :authorize_read

  def index
    response.headers['Cache-Control'] = 'no-store'
    @crosswalk = ProductNameCrosswalk.new
    if request.format.csv?
      log_export('Product names CSV')
      send_data @crosswalk.csv, filename: "product-names-#{Date.current.iso8601}.csv", type: 'text/csv'
    else
      @filter = %w[verify unmatched].include?(params[:filter]) ? params[:filter] : 'all'
      @query = params[:q].to_s.strip[0, 255]
      @rows = @filter == 'unmatched' ? [] : filtered_rows
      @unmatched_items = @filter == 'verify' ? [] : filtered_unmatched
      @pagy = Pagy.new(count: @rows.size, page: params[:page], items: 50)
      @page_rows = @rows.slice(@pagy.offset, @pagy.items) || []
    end
  end

  def pdf
    sheet = params[:sheet].to_s
    return head(:not_found) unless ProductNamePdf::SHEETS.key?(sheet)

    log_export("Product names PDF (#{sheet})")
    send_data ProductNamePdf.build(sheet, ProductNameCrosswalk.new), filename: "product-names-#{sheet}-#{Date.current.iso8601}.pdf",
      type: 'application/pdf', disposition: 'inline'
  end

  private

  def authorize_read
    authorize(:module, :inventory_read?)
  end

  def filtered_rows
    rows = @crosswalk.rows
    rows = rows.select { |r| r[:issues].any? } if @filter == 'verify'
    return rows if @query.blank?

    rows.select do |r|
      [r[:name], r[:sku], *%i[square swipesimple ctrax].map { |s| r.dig(s, :name) }].compact.join(' ').downcase.include?(@query.downcase)
    end
  end

  def filtered_unmatched
    items = @crosswalk.unmatched_list
    return items if @query.blank?

    items.select { |i| [i[:name], i[:sku], i[:suggestion]].compact.join(' ').downcase.include?(@query.downcase) }
  end
end
