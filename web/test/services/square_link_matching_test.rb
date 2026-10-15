# frozen_string_literal: true

require 'test_helper'

class SquareLinkMatchingTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'unique normalized SKUs link exactly once without rewriting unchanged records' do
    variant = create_variant(sku: ' Tea-50 ')
    catalog = [square_row('square-1', 'tea-50')]
    assert_equal 1, sync_links(catalog)
    link = SkuLink.find_by!(shopifyVariantId: variant.id)
    assert_equal 'square-1', link.squareVariationId
    assert_equal 'sku', link.matchSource
    assert link.auto
    original = link.attributes

    assert_equal 1, sync_links(catalog)
    assert_equal original, link.reload.attributes
  end

  test 'manual mappings remain intact despite a competing matching SKU' do
    variant = create_variant(sku: 'TEA-50')
    link = create_link(variant, 'chosen-square', auto: false, source: 'manual')
    original = link.attributes

    assert_equal 0, sync_links([square_row('automatic-square', 'TEA-50')])
    assert_equal original, link.reload.attributes
  end

  test 'audit mappings and explicitly nonautomatic SKU mappings remain intact' do
    audit = create_variant(sku: 'AUDIT')
    deliberate = create_variant(sku: 'DELIBERATE')
    first = create_link(audit, 'audit-target', source: 'audit-link')
    second = create_link(deliberate, 'deliberate-target', auto: false)
    before = [first.attributes, second.attributes]

    sync_links([square_row('auto-audit', 'AUDIT'), square_row('auto-deliberate', 'DELIBERATE')])
    assert_equal before, [first.reload.attributes, second.reload.attributes]
  end

  test 'duplicate Square SKUs invalidate only automatic links instead of choosing the last variation' do
    variant = create_variant(sku: 'TEA-50')
    link = create_link(variant, 'square-1')
    catalog = [square_row('square-1', ' tea-50 '), square_row('square-2', 'TEA-50')]

    assert_equal 0, sync_links(catalog)
    assert_nil link.reload.squareVariationId
    assert link.auto
    assert_equal 'sku', link.matchSource
    refute SkuLink.linked.exists?(shopifyVariantId: variant.id)
    assert_equal 0, sync_links(catalog.reverse)
    assert_nil link.reload.squareVariationId
  end

  test 'duplicate Shopify SKUs cannot auto claim one Square variation' do
    first = create_variant(sku: 'TEA-50')
    second = create_variant(sku: ' tea-50 ')
    link = create_link(first, 'square-1')

    assert_equal 0, sync_links([square_row('square-1', 'Tea-50')])
    assert_nil link.reload.squareVariationId
    assert_nil SkuLink.find_by(shopifyVariantId: second.id)
  end

  test 'an existing manual target cannot be automatically shared by another variant' do
    manual = create_variant(sku: 'DIFFERENT')
    automatic = create_variant(sku: 'TEA-50')
    chosen = create_link(manual, 'square-1', auto: false, source: 'manual')

    assert_equal 0, sync_links([square_row('square-1', 'TEA-50')])
    assert_equal 'square-1', chosen.reload.squareVariationId
    assert_nil SkuLink.find_by(shopifyVariantId: automatic.id)
  end

  test 'missing and blank SKU candidates invalidate automatic mappings' do
    missing = create_variant(sku: 'MISSING')
    blank = create_variant(sku: ' ')
    first = create_link(missing, 'old-square')
    second = create_link(blank, 'old-blank', sku: 'OLD')

    assert_equal 0, sync_links([])
    assert_nil first.reload.squareVariationId
    assert_nil second.reload.squareVariationId
  end

  test 'wholesale products do not retain an automatic Square claim' do
    variant = create_variant(sku: 'BULK', tags: 'retail, wholesale')
    link = create_link(variant, 'square-bulk')

    assert_equal 0, sync_links([square_row('square-bulk', 'BULK')])
    assert_nil link.reload.squareVariationId
  end

  test 'a stale automatic snapshot cannot overwrite a newly saved manual choice' do
    variant = create_variant(sku: 'TEA-50')
    link = create_link(variant, 'old-target')
    snapshot = SkuLink.find(link.id)
    square_row('chosen-target', 'CHOSEN')
    link.update!(squareVariationId: 'chosen-target', matchSource: 'manual', auto: false)
    original = link.attributes
    stub_link_snapshot([snapshot])

    assert_equal 0, sync_links([square_row('automatic-target', 'TEA-50')])
    assert_equal original, link.reload.attributes
  end

  test 'a concurrent new manual link wins the unique variant key' do
    variant = create_variant(sku: 'TEA-50')
    chosen = create_link(variant, 'chosen-target', auto: false, source: 'manual')
    original = chosen.attributes
    stub_link_snapshot([])

    assert_equal 0, sync_links([square_row('automatic-target', 'TEA-50')])
    assert_equal original, chosen.reload.attributes
  end

  test 'identical foreign SKUs and explicit foreign targets do not affect this tenant' do
    variant = create_variant(sku: 'TEA-50')
    home = Current.tenant
    foreign = Tenant.create!(name: 'Other matching store', subdomain: 'other-matching-store')
    Current.tenant = foreign
    other_variant = create_variant(sku: 'TEA-50')
    other_link = create_link(other_variant, 'foreign-square', auto: false, source: 'manual')
    original = other_link.attributes
    Current.tenant = home

    assert_equal 0, sync_links([{ variationId: 'foreign-square', sku: 'TEA-50' }])
    assert_nil SkuLink.find_by(shopifyVariantId: variant.id)
    assert_equal 1, sync_links([square_row('square-1', 'TEA-50')])
    assert_equal 'square-1', SkuLink.find_by!(shopifyVariantId: variant.id).squareVariationId
    assert_equal original, SkuLink.unscoped.find(other_link.id).attributes
    assert_equal 2, SkuLink.unscoped.count
  end

  test 'a duplicated source variation ID with conflicting SKUs cannot identify two Shopify variants' do
    first = create_variant(sku: 'FIRST')
    second = create_variant(sku: 'SECOND')
    first_row = square_row('shared-identity', 'FIRST')

    assert_equal 0, sync_links([first_row, { variationId: 'shared-identity', sku: 'SECOND' }])
    assert_nil SkuLink.find_by(shopifyVariantId: first.id)
    assert_nil SkuLink.find_by(shopifyVariantId: second.id)
  end

  test 'automatic mappings to foreign-owned parents become unresolved while explicit mappings remain intact' do
    first = create_variant(sku: 'AUTO')
    second = create_variant(sku: 'MANUAL')
    automatic = create_link(first, 'old-auto')
    manual = create_link(second, 'old-manual', auto: false, source: 'manual')
    original = manual.attributes
    foreign = Tenant.create!(name: 'Foreign parent store', subdomain: 'foreign-parent-store')
    ShopifyVariant.where(id: [first.id, second.id]).update_all(tenant_id: foreign.id)

    assert_equal 0, sync_links([])
    assert_nil automatic.reload.squareVariationId
    assert_equal original, manual.reload.attributes
  end

  private

  def create_variant(sku:, tags: nil)
    product = ShopifyProduct.create!(id: SecureRandom.uuid, title: 'Matching product', tags: tags)
    ShopifyVariant.create!(id: SecureRandom.uuid, productId: product.id, sku: sku, title: 'Matching variant')
  end

  def create_link(variant, target, auto: true, source: 'sku', sku: variant.sku)
    square_row(target, 'MANUAL-TARGET') unless SquareVariation.exists?(id: target)
    SkuLink.create!(shopifyVariantId: variant.id, squareVariationId: target, sku: sku,
      auto: auto, matchSource: source)
  end

  def square_row(id, sku)
    unless SquareVariation.exists?(id: id)
      item = SquareItem.create!(id: "item-#{id}", name: 'Matching Square item')
      SquareVariation.create!(id: id, itemId: item.id, name: 'Matching Square variation', sku: sku)
    end
    { variationId: id, sku: sku }
  end

  def stub_link_snapshot(links)
    relation = SkuLink.all
    relation.stubs(:index_by).returns(links.index_by(&:shopifyVariantId))
    SkuLink.stubs(:all).returns(relation)
  end

  def sync_links(catalog)
    SquareSyncer.send(:sync_links!, catalog)
  end
end
