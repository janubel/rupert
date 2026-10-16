# frozen_string_literal: true

class PosDisplaysController < AuthenticatedController
  rescue_from Pos::Error do |error|
    render json: { error: error.message }, status: :conflict
  end
  before_action do
    authorize(:module, :sales_write?)
    authorize(:module, :sales_read?)
    authorize(:module, :inventory_read?)
    response.headers['Cache-Control'] = 'no-store'
  end

  def create
    snapshot = CtraxStockSnapshot.find_by!(location_id: params[:location_id])
    display = PosDisplaySession.create!(user: Current.user, location: snapshot.location, demo: params[:demo] == '1')
    if display.demo?
      record = snapshot.records.find { |row| row['price_cents'].is_a?(Integer) && row['price_cents'].positive? && !row['variable_price'] && row['listed'] != false }
      if record
        amount = (BigDecimal(record['price_cents'].to_s) / 100).to_s('F')
        quote = { source: 'ctrax', currency_code: 'USD', preview: true,
          subtotal: amount, lines: [{ variant_id: record['id'], sku: record['sku'], product_title: record['product_name'] || record['name'],
            title: record['name'], quantity: 1, unit_price: amount, line_total: amount,
            thumbnail_url: Ctrax::CatalogImages.new(snapshot.location).url(record) }] }
        Pos::Quote.decorate!(quote, snapshot, demo: true)
        display.publish!(quote.deep_stringify_keys)
      end
      redirect_to demo_pos_display_path(display)
    else
      redirect_to ctrax_pos_path(location_id: snapshot.location_id, display_id: display.id)
    end
  end

  def show
    display = PosDisplaySession.find_by!(id: params[:id], user_id: Current.user.id)
    render json: display.public_state.slice(:active, :confirmed, :cart_revision, :subtotal_cents, :tip_cents, :demo, :checkout, :tax_cents, :tax_verified)
  end

  def clear
    display = PosDisplaySession.find_by!(id: params[:id], user_id: Current.user.id)
    display.publish!({ 'lines' => [], 'subtotal' => '0', 'currency_code' => 'USD', 'preview' => true })
    head :no_content
  end

  def destroy
    display = PosDisplaySession.find_by!(id: params[:id], user_id: Current.user.id)
    display.update!(closed_at: Time.current)
    redirect_to ctrax_pos_path(location_id: display.location_id), notice: 'Customer screen closed.'
  end

  def demo
    @display = PosDisplaySession.find_by!(id: params[:id], user_id: Current.user.id, demo: true)
  end
end
