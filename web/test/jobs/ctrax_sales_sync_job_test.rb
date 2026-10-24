# frozen_string_literal: true

require 'test_helper'

class CtraxSalesSyncJobTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'sales-job/1', name: 'Main')
  end

  teardown { Current.reset }

  def at(text) = Time.find_zone('America/New_York').parse(text)

  def store(day)
    CtraxDay.create!(location: @location, business_date: day, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1',
      timezone: 'America/New_York', source_digest: SecureRandom.hex(8), captured_at: Time.current, orders_json: [], sessions_json: [], controls_json: {})
  end

  test 'a daytime run reads today, yesterday and any day of the last week never stored' do
    today = Date.new(2026, 10, 23)
    ((today - 6)..today).each { |day| store(day) unless day == today - 3 }
    assert_equal [today, today - 1, today - 3], CtraxSalesSyncJob.dates_to_read(now: at('2026-10-23 14:05'))
  end

  test 'with nothing stored the whole last week is read' do
    assert_equal 7, CtraxSalesSyncJob.dates_to_read(now: at('2026-10-23 14:05')).size
  end

  test 'the run in the 3 a.m. hour re-reads the whole last week so older corrections arrive' do
    today = Date.new(2026, 10, 23)
    ((today - 6)..today).each { |day| store(day) }
    assert_equal ((today - 6)..today).to_a.reverse, CtraxSalesSyncJob.dates_to_read(now: at('2026-10-23 03:05'))
    assert_equal [today, today - 1], CtraxSalesSyncJob.dates_to_read(now: at('2026-10-23 03:35'))
  end
end
