# frozen_string_literal: true

require 'test_helper'

class CatalogMappingLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'a concurrent automatic match waits for a manual target decision before reading ownership' do
    tenant = Tenant.create!(name: 'Catalog lock race', subdomain: "catalog-lock-#{SecureRandom.hex(4)}")
    Current.tenant = tenant
    product = ShopifyProduct.create!(id: SecureRandom.uuid, title: 'Mapping lock product')
    automatic = ShopifyVariant.create!(id: SecureRandom.uuid, productId: product.id, title: 'Automatic item', sku: 'TEA')
    manual = ShopifyVariant.create!(id: SecureRandom.uuid, productId: product.id, title: 'Manual item', sku: 'DIFFERENT')
    item = SquareItem.create!(id: SecureRandom.uuid, name: 'Mapping lock Square product')
    target = SquareVariation.create!(id: SecureRandom.uuid, itemId: item.id, name: 'Target item', sku: 'TEA')
    held = Queue.new
    release = Queue.new
    attempting = Queue.new
    outcomes = Queue.new

    manual_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.tenant = tenant
        CatalogMappingLock.synchronize do
          SkuLink.create!(shopifyVariantId: manual.id, squareVariationId: target.id, sku: manual.sku,
            auto: false, matchSource: 'manual')
          held << true
          release.pop
        end
        outcomes << :manual
      ensure
        Current.reset
      end
    rescue StandardError => error
      held << error
      outcomes << error
    end

    assert_equal true, held.pop
    automatic_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.tenant = tenant
        attempting << true
        outcomes << SquareSyncer.send(:sync_links!, [{ variationId: target.id, sku: 'TEA' }])
      ensure
        Current.reset
      end
    rescue StandardError => error
      outcomes << error
    end
    attempting.pop
    refute automatic_thread.join(0.1), 'matching must wait while the manual mapping transaction owns the tenant lock'
    release << true
    [manual_thread, automatic_thread].each { |thread| assert thread.join(15), 'mapping transaction timed out' }
    results = Array.new(2) { outcomes.pop }
    results.each { |result| refute_kind_of Exception, result, result.inspect }
    assert_includes results, 0
    Current.tenant = tenant
    assert_equal target.id, SkuLink.find_by!(shopifyVariantId: manual.id).squareVariationId
    assert_nil SkuLink.find_by(shopifyVariantId: automatic.id)
    assert_equal 1, SkuLink.linked.count
  ensure
    release << true if release
    [manual_thread, automatic_thread].compact.each do |thread|
      thread.join(2)
      thread.kill if thread.alive?
    end
    if tenant
      SkuLink.unscoped.where(tenant_id: tenant.id).delete_all
      SquareVariation.unscoped.where(tenant_id: tenant.id).delete_all
      SquareItem.unscoped.where(tenant_id: tenant.id).delete_all
      ShopifyVariant.unscoped.where(tenant_id: tenant.id).delete_all
      ShopifyProduct.unscoped.where(tenant_id: tenant.id).delete_all
      tenant.destroy!
    end
    Current.reset
  end
end
