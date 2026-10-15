# frozen_string_literal: true

require 'test_helper'

class EnvStoreTest < ActiveSupport::TestCase
  setup do
    RequestStore.clear!
    @first = tenants(:default_tenant)
    @second = Tenant.create!(name: 'Other credential store', subdomain: 'env-cache-other')
    Setting.create!(key: 'SQUARE_ACCESS_TOKEN', tenant: @first, value: 'first-tenant-token')
    Setting.create!(key: 'SQUARE_ACCESS_TOKEN', tenant: @second, value: 'second-tenant-token')
    Setting.create!(key: 'SQUARE_ACCESS_TOKEN', tenant_id: nil, value: 'platform-only-token')
  end

  teardown do
    Current.reset
    RequestStore.clear!
  end

  test 'same-thread tenant switches never reuse another store or platform credentials' do
    Current.tenant = nil
    assert_equal 'platform-only-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = @first
    assert_equal 'first-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = @second
    assert_equal 'second-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = @first
    assert_equal 'first-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = nil
    assert_equal 'platform-only-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end

  test 'reads remain memoized per store across repeated context switches' do
    count = setting_reads do
      3.times do
        Current.tenant = @first
        assert_equal 'first-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
        assert_equal 'missing', EnvStore.fetch('SHOPIFY_CLIENT_SECRET', 'missing')
        Current.tenant = @second
        assert_equal 'second-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
      end
    end
    assert_equal 2, count
  end

  test 'setting a credential invalidates only that stores cached map' do
    warm_both
    Current.tenant = @first
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'updated-first-token')
    count = setting_reads do
      Current.tenant = @second
      assert_equal 'second-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
      Current.tenant = @first
      assert_equal 'updated-first-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    end
    assert_equal 1, count
    encrypted = Setting.find_by!(tenant_id: @first.id, key: 'SQUARE_ACCESS_TOKEN').value_before_type_cast
    refute_includes encrypted, 'updated-first-token'
  end

  test 'import refreshes the current store without replacing another stores map' do
    warm_both
    Current.tenant = @second
    assert_equal ['SQUARE_ACCESS_TOKEN'], EnvStore.import!("SQUARE_ACCESS_TOKEN=imported-second-token")
    count = setting_reads do
      Current.tenant = @first
      assert_equal 'first-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
      Current.tenant = @second
      assert_equal 'imported-second-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    end
    assert_equal 1, count
  end

  test 'deletion refreshes its store and never falls back to platform credentials' do
    warm_both
    Current.tenant = @first
    EnvStore.set('SQUARE_ACCESS_TOKEN', nil)
    assert_equal 'missing', EnvStore.fetch('SQUARE_ACCESS_TOKEN', 'missing')
    Current.tenant = @second
    assert_equal 'second-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = nil
    assert_equal 'platform-only-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    EnvStore.set('SQUARE_ACCESS_TOKEN', nil)
    Current.tenant = @second
    assert_equal 'second-tenant-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end

  private

  def warm_both
    Current.tenant = @first
    EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    Current.tenant = @second
    EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end

  def setting_reads
    count = 0
    listener = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:name] != 'SCHEMA' && payload[:sql].match?(/\bSELECT\b.*\bFROM\s+"?settings"?/i)
    end
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') { yield }
    count
  end
end
