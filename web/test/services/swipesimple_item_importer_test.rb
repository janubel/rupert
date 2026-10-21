# frozen_string_literal: true

require 'test_helper'

class SwipesimpleItemImporterTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'recognises common SwipeSimple column names and keeps unknown stock unknown' do
    csv = "﻿Item Name,Option,SKU,UPC,Price,In Stock,Category,Notes\n" \
          "Blue Dream,3.5g,BD-35,,$35.00,12,Flower,x\n" \
          "Calm Gummies,Default,GUM-10,012345678905,\"1,020.50\",,Edibles,\n"
    preview = SwipesimpleItemImporter.preview(csv)
    first, second = preview.records
    assert_equal({ name: 'Item Name', variant: 'Option', sku: 'SKU', barcode: 'UPC', price: 'Price', quantity: 'In Stock', category: 'Category' }, preview.mapped)
    assert_equal ['Notes'], preview.ignored
    assert_equal ['Blue Dream 3.5g', 'Blue Dream', 'BD-35', '12', true, 3500], first.values_at('name', 'product_name', 'id', 'quantity', 'manage_stock', 'price_cents')
    assert_equal ['Calm Gummies', nil, false, '1020.5'], second.values_at('name', 'quantity', 'manage_stock', 'price')
    assert_match(/1 item has no stock figure/, preview.warnings.join)
  end

  test 'rejects files it cannot trust and saves nothing' do
    assert_raises(SwipesimpleItemImporter::Error) { SwipesimpleItemImporter.preview('') }
    assert_raises(SwipesimpleItemImporter::Error) { SwipesimpleItemImporter.preview("SKU,Price\nA,1\n") }
    assert_raises(SwipesimpleItemImporter::Error) { SwipesimpleItemImporter.preview("Name,SKU\nA,X\nB,X\n") }
    error = assert_raises(SwipesimpleItemImporter::Error) { SwipesimpleItemImporter.preview("Name,Quantity\nA,lots\n") }
    assert_match(/Row 2/, error.message)
    assert_no_difference('SwipesimpleItemSnapshot.count') do
      assert_raises(SwipesimpleItemImporter::Error) { SwipesimpleItemImporter.import!("Name,Quantity\nA,lots\n", merchant_account: 'Shop') }
    end
  end

  test 'a new import replaces the list for that merchant account' do
    SwipesimpleItemImporter.import!("Name,Quantity\nA,1\n", merchant_account: 'Shop')
    snapshot, = SwipesimpleItemImporter.import!("Name,Quantity\nB,2\nC,3\n", merchant_account: 'Shop', filename: 'items.csv')
    assert_equal 1, SwipesimpleItemSnapshot.count
    assert_equal %w[B C], snapshot.reload.records.map { |r| r['name'] }
    assert_equal 'items.csv', snapshot.source_filename
  end
end
