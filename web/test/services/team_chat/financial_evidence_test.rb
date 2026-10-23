# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatFinancialEvidenceTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.direct_for(@user)
    @period = { from: Date.current.iso8601, to: Date.current.iso8601 }
  end
  teardown { Current.reset }

  def data(value = 21483, currency = 'USD')
    { metric: 'gross_sales', source: 'shopify', period: @period, values: [{ value: value, currency: currency }] }
  end

  def evidence(payload = data, args: { name: 'gross_sales', period: 'today', source: 'shopify' }, tool: 'metric', invocation: 'call-1')
    TeamChat::FinancialEvidence.build(tool: tool, data: payload, arguments: args, tenant_id: @user.tenant_id, invocation: invocation)
  end

  def render(item) = TeamChat::FinancialEvidence.render([item])

  test 'a fact binds its signed decimal value to source period currency meaning tool field and tenant' do
    fact = evidence.fetch('facts').sole
    assert_equal '214.83', fact['value']
    assert_equal 'USD', fact['currency']
    assert_equal @period.stringify_keys, fact['period']
    assert_equal Time.zone.name, fact['timezone']
    assert_includes fact['meaning'], 'Gross sales'
    assert_includes fact['source'], 'shopify'
    assert_equal @user.tenant_id, fact['tenant_id']
    assert_equal 'metric', fact['tool']
    assert_equal 'values.0.value', fact['field']
  end

  test 'the same numeric value in another source period currency or metric has a different identity' do
    base = evidence['facts'].sole['id']
    square = evidence(data.merge(source: 'square'), args: { name: 'gross_sales', period: 'today', source: 'square' })
    cad = evidence(data(21483, 'CAD'))
    orders = evidence(data(21483).merge(metric: 'orders'), args: { name: 'orders', period: 'today', source: 'shopify' })
    yesterday = @period.transform_values { (Date.current - 1).iso8601 }
    previous = evidence(data.merge(period: yesterday), args: { name: 'gross_sales', period: 'yesterday', source: 'shopify' })
    ids = [square, cad, orders, previous].map { |item| item['facts'].sole['id'] }
    assert_equal 5, [base, *ids].uniq.size
  end

  test 'explicit request source and period mismatches fail closed instead of matching the amount' do
    assert_empty evidence(data.merge(source: 'square'))['facts']
    assert_empty evidence(data.merge(period: { from: '2020-01-01', to: '2020-01-02' }))['facts']
    assert_empty evidence(data.merge(metric: 'orders'))['facts']
  end

  test 'unknown currency and nil are unavailable while zero remains a verified zero' do
    [nil, '', 'ZZZ', 'JPY'].each { |currency| assert_empty evidence(data(0, currency))['facts'] }
    assert_empty evidence(data(nil))['facts']
    assert_includes render(evidence(data(0))), '0.00 USD'
    assert_not_includes render(evidence(data(nil))), '0.00 USD'
  end

  test 'negative amounts and large integer cents are never converted through floats or absolute values' do
    assert_includes render(evidence(data(-1))), '-0.01 USD'
    assert_includes render(evidence(data(900719925474099301))), '9007199254740993.01 USD'
    assert_empty evidence(data(12.34))['facts']
  end

  test 'refund rates remain percentages rather than money or percentage points' do
    item = evidence(data(-12.5).merge(metric: 'refund_rate'), args: { name: 'refund_rate', period: 'today', source: 'shopify' })
    assert_includes render(item), '-12.5% USD'
    assert_includes render(item), 'percentage of gross sales'
    assert_equal 'percent', item['facts'].sole['unit']
  end

  test 'comparison values retain their own period and relative changes name the baseline' do
    payload = data.merge(compared_with: { from: (Date.current - 1).iso8601, to: (Date.current - 1).iso8601, values: [{ value: 21483, currency: 'USD' }] }, change: [{ change_percent: 0, currency: 'USD' }])
    facts = evidence(payload)['facts']
    assert_equal 3, facts.size
    assert_not_equal facts[0]['period'], facts[1]['period']
    assert_includes facts[2]['meaning'], "versus #{Date.current - 1}"
    assert_equal '0.0', facts[2]['value']
  end

  test 'sales tax and gross with the same amount keep distinct meanings and fields' do
    payload = @period.merge(lines: [{ source: 'shopify', currency: 'CAD', gross_cents: 100, tax_cents: 100, orders: 1 }])
    item = evidence(payload, tool: 'sales_summary', args: @period.merge(source: 'shopify'))
    assert_equal ['Gross sales (paid or fulfilled orders)', 'Order tax', 'Paid or fulfilled order count'], item['facts'].pluck('meaning')
    assert_equal 3, item['facts'].pluck('id').uniq.size
    assert_includes render(item), '1.00 CAD'
  end

  test 'review expenses with no currency cannot masquerade as USD or profit' do
    payload = @period.merge(sales: [{ currency: 'CAD', gross_cents: 10000 }], activity: { expenses_cents: 12345 })
    item = evidence(payload, tool: 'period_review', args: @period)
    assert_equal 1, item['facts'].size
    assert_not_includes render(item), '123.45'
    assert_includes render(item), 'Expenses without explicit currency'
  end

  test 'unsupported financial tools and unknown metric meanings return no certified figures' do
    assert_empty evidence({ amount_cents: 99900 }, tool: 'unsupported_finance_tool')['facts']
    assert_empty evidence(data.merge(metric: 'profit'), args: { name: 'profit', period: 'today', source: 'shopify' })['facts']
  end

  test 'tax evidence keeps stores sources and estimates separate from reported tax' do
    payload = @period.merge(lines: [
      { source: 'Square', store: 'Store A', currency: 'USD', tax_collected: 100, estimated_tax: nil },
      { source: 'SwipeSimple', store: 'Store A', currency: 'USD', tax_collected: nil, estimated_tax: 100 }
    ])
    item = evidence(payload, tool: 'sales_tax_report', args: @period)
    assert_equal ['Reported tax collected', 'Estimated tax (not reported tax)'], item['facts'].pluck('meaning')
    assert_includes render(item), 'Square / store'
    assert_includes render(item), 'SwipeSimple / store'
    assert_not_includes render(item), '2.00 USD'
  end

  test 'source share percentages carry their own source and currency denominator' do
    payload = data.merge(source: nil, metric: 'sales_by_source', values: [{ currency: 'USD', sources: [{ source: 'square', gross_cents: 100, share_percent: 25 }] }])
    item = evidence(payload, args: { name: 'sales_by_source', period: 'today' })
    assert_empty evidence(payload.merge(source: 'shopify'), args: { name: 'sales_by_source', period: 'today', source: 'shopify' })['facts']
    assert_includes render(item), '25% USD'
    assert_includes render(item), 'square canonical orders'
    assert_includes render(item), 'Share of gross sales in this currency'
  end

  test 'durable envelopes reject another tenant invocation or tampered dimension' do
    item = evidence
    text = JSON.generate(item)
    assert TeamChat::FinancialEvidence.decode(text, @user.tenant_id, tool: 'metric', invocation: 'call-1')
    assert_nil TeamChat::FinancialEvidence.decode(text, 'another-tenant')
    assert_nil TeamChat::FinancialEvidence.decode(text, @user.tenant_id, invocation: 'call-2')
    item['facts'][0]['currency'] = 'CAD'
    assert_nil TeamChat::FinancialEvidence.decode(JSON.generate(item), @user.tenant_id)
  end

  test 'oversized results retain valid complete facts with an explicit omission notice' do
    payload = data.merge(values: 100.times.map { |i| { value: i, currency: 'USD' } })
    item = evidence(payload)
    assert_operator JSON.generate(item).size, :<=, 5500
    assert_operator item['facts'].size, :<=, 12
    assert_includes item['gaps'].join, 'omitted'
    assert TeamChat::FinancialEvidence.decode(JSON.generate(item), @user.tenant_id)
  end

  test 'a model cannot relabel gross as profit swap currency period or invent a figure in its prose' do
    Core::Order.create!(source: 'shopify', source_order_id: 'evidence-order', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } }, { text: 'Last year profit was 214.83 CAD and tax was $999.99.' })
    reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert gross sales today from Shopify').reply
    TeamChat::Agent.new(reply, config: team_chat_config).run
    body = reply.reload.body
    assert_includes body, '214.83 USD'
    assert_includes body, Date.current.iso8601
    assert_includes body, 'Gross sales'
    assert_not_includes body, 'Last year'
    assert_not_includes body, 'CAD'
    assert_not_includes body, '999.99'
    assert_equal 1, reply.run.reload.tool_results.size
    assert_equal reply.meta['financial_evidence'].first['facts'], JSON.parse(reply.run.tool_results.first['result'])['facts']
  end

  test 'conversation amounts and bare model prose are never financial evidence' do
    script_model({ text: 'You made $100 profit.' })
    reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert did we make $100 profit?').reply
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'could not verify'
    assert_not_includes reply.body, '$100'
  end
  test 'recovered tool results restore the same facts without accepting a forged lookup result' do
    reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert show gross sales').reply
    item = evidence
    reply.run.update!(tool_results: [{ 'id' => 'call-1', 'name' => 'metric', 'result' => JSON.generate(item), 'arguments' => {} }])
    execution = TeamChat::Execution.new(reply.run, reply.run.claim!)
    toolbox = TeamChat::Toolbox.new(user: @user, room: @room, reply: reply, execution: execution)
    assert_equal [item], toolbox.financial_evidence
    assert toolbox.financial?
    reply.run.update!(tool_results: [{ 'id' => 'call-1', 'name' => 'search', 'result' => JSON.generate(item), 'arguments' => {} }])
    toolbox = TeamChat::Toolbox.new(user: @user, room: @room, reply: reply, execution: execution)
    assert_empty toolbox.financial_evidence
  end

  test 'draft financial and numeric chunks never reach the streaming write path' do
    reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert show figures').reply
    agent = TeamChat::Agent.new(reply, config: team_chat_config)
    context = mock('execution')
    context.expects(:write_reply!).never
    agent.instance_variable_set(:@execution, context)
    agent.send(:publish, 'Profit $999.99')
    agent.send(:publish, '123')
    toolbox = mock('financial toolbox')
    toolbox.stubs(:financial?).returns(true)
    agent.instance_variable_set(:@toolbox, toolbox)
    agent.send(:publish, 'Profit was great')
  end

  test 'an all-missing oversized result terminates with an unavailable answer' do
    payload = data.merge(values: 100.times.map { { value: nil, currency: nil } })
    assert_empty evidence(payload)['facts']
    assert_includes render(evidence(payload)), 'missing data does not prove zero'
  end

  test 'store contact details are not introduced into model evidence' do
    payload = @period.merge(lines: [{ source: 'Square', store: 'customer@example.com', currency: 'USD', tax_collected: 100 }])
    item = evidence(payload, tool: 'sales_tax_report', args: @period)
    assert_empty item['facts']
    assert_not_includes JSON.generate(item), 'customer@example.com'
    payload[:lines][0][:store] = 'x' * 257
    assert_empty evidence(payload, tool: 'sales_tax_report', args: @period)['facts']
  end
end
