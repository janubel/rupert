# frozen_string_literal: true

require 'test_helper'

class ApplePayDomainTest < ActionDispatch::IntegrationTest
  PATH = '/.well-known/apple-developer-merchantid-domain-association'

  setup { Current.tenant = tenants(:default_tenant) }

  teardown do
    Current.tenant = tenants(:default_tenant)
    EnvStore.set('APPLE_PAY_DOMAIN_ASSOCIATION', nil)
    Current.reset
  end

  test 'serves the pasted domain-association file to Apple without signing in' do
    EnvStore.set('APPLE_PAY_DOMAIN_ASSOCIATION', "7B2270737022...  \n")
    Current.reset
    Tenant.stub(:count, 1) do
      Tenant.stub(:first, tenants(:default_tenant)) do
        get PATH
      end
    end
    assert_response :success
    assert_equal '7B2270737022...', response.body
    assert_equal 'text/plain', response.media_type
  end

  test 'is not found until the file is set' do
    Current.reset
    Tenant.stub(:count, 1) { Tenant.stub(:first, tenants(:default_tenant)) { get PATH } }
    assert_response :not_found
  end
end
