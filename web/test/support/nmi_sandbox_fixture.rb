# frozen_string_literal: true

module NmiSandboxFixture
  def prepare_nmi_fixture
    @nmi_mode = :approved
    @nmi_sales = 0
    @nmi_company = 'Sandbox Company'
    @nmi_currency = 'USD'
    @nmi_amount = '11.66'
    @nmi_condition = 'pendingsettlement'
    @nmi_order_override = nil
    @nmi_xml_override = nil
    stub_request(:post, Pos::NmiGateway::SALE_URL).to_return do |request|
      @nmi_sales += 1
      assert_equal 'sandbox-private-fixture', request.headers['Authorization']
      body = JSON.parse(request.body)
      @nmi_invoice = body.dig('order_details', 'id')
      assert_equal '11.66', body['amount']
      assert_equal 'USD', body['currency']
      assert_equal %w[payment_token], body.fetch('payment_details').keys
      @nmi_during_sale&.call
      raise Net::ReadTimeout if @nmi_mode == :timeout
      data = { id: '12345', response: @nmi_mode == :declined ? '2' : '1' }
      { status: 200, body: @nmi_mode == :malformed ? '{not json' : data.to_json }
    end
    stub_request(:post, Pos::NmiGateway::QUERY_URL).to_return do |request|
      fields = URI.decode_www_form(request.body).to_h
      assert_equal 'sandbox-private-fixture', fields.fetch('security_key')
      body = if fields['report_type'] == 'profile'
        "<nm_response><merchant><company>#{@nmi_company}</company></merchant></nm_response>"
      else
        assert_equal @nmi_invoice, fields['order_id']
        @nmi_xml_override || nmi_transaction_xml
      end
      { status: 200, body: body }
    end
  end

  def nmi_transaction_xml
    "<nm_response><transaction><transaction_id>12345</transaction_id><transaction_type>cc</transaction_type>" \
      "<condition>#{@nmi_condition}</condition><order_id>#{@nmi_order_override || @nmi_invoice}</order_id>" \
      "<currency>#{@nmi_currency}</currency><action><action_type>sale</action_type><success>1</success>" \
      "<amount>#{@nmi_amount}</amount></action></transaction></nm_response>"
  end

  def nmi_credentials
    { security_key: 'sandbox-private-fixture', tokenization_key: 'sandbox-public-fixture', merchant_company: 'Sandbox Company' }.to_json
  end
end
