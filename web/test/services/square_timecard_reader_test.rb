# frozen_string_literal: true

require 'test_helper'

class SquareTimecardReaderTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    SquareClient.stubs(:configured?).returns(true)
    SquareClient.stubs(:token).returns('source-token')
    SquareClient.stubs(:environment).returns('production')
  end
  teardown { Current.reset }

  test 'complete pagination uses only the read endpoint and verifies the same connection' do
    SquareClient.expects(:request).with('/labor/timecards/search', method: 'POST', body: { limit: 200, query: { sort: { field: 'START_AT', order: 'ASC' } } }).returns({ 'timecards' => [{ 'id' => 'one' }], 'cursor' => 'next' })
    SquareClient.expects(:request).with('/labor/timecards/search', method: 'POST', body: { limit: 200, query: { sort: { field: 'START_AT', order: 'ASC' } }, cursor: 'next' }).returns({ 'timecards' => [{ 'id' => 'two' }] })
    reader = SquareTimecardReader.new
    assert_equal %w[one two], reader.call.map { |row| row['id'] }
    reader.verify_connection!
    SquareClient.stubs(:token).returns('different-token')
    assert_raises(SquareTimecardReader::Error) { reader.verify_connection! }
  end

  test 'repeated IDs repeated cursors and upstream failures cannot publish partial hours' do
    [
      [{ 'timecards' => [{ 'id' => 'one' }], 'cursor' => 'next' }, { 'timecards' => [{ 'id' => 'one' }] }],
      [{ 'timecards' => [{ 'id' => 'one' }], 'cursor' => 'next' }, { 'timecards' => [{ 'id' => 'two' }], 'cursor' => 'next' }],
      [{ 'timecards' => [{ 'id' => 'one' }], 'cursor' => 'next' }, { 'errors' => [{ 'code' => 'FAILED' }] }]
    ].each do |pages|
      SquareClient.stubs(:request).returns(*pages)
      assert_no_difference ['SquareTimecard.count', 'SquareTimecardDay.count'] do
        assert_raises(SquareTimecardReader::Error) { SquareTimecardReader.new.call }
      end
    end
  end
end
