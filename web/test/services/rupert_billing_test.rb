# frozen_string_literal: true

require 'test_helper'

class RupertBillingTest < ActiveSupport::TestCase
  setup do
    @saved = ENV.to_h.slice('RUPERT_BILLING_ENABLED', 'CSP_STRIPE_SECRET_KEY', 'CSP_STRIPE_ACCOUNT_ID', 'CSP_STRIPE_MONTHLY_PRICE_ID', 'CSP_STRIPE_REFERRAL_COUPON_ID', 'CSP_STRIPE_WEBHOOK_SECRET')
    ENV.update('RUPERT_BILLING_ENABLED' => 'true', 'CSP_STRIPE_SECRET_KEY' => 'sk_test_fixture', 'CSP_STRIPE_ACCOUNT_ID' => 'acct_csp', 'CSP_STRIPE_MONTHLY_PRICE_ID' => 'price_monthly', 'CSP_STRIPE_REFERRAL_COUPON_ID' => 'coupon_year', 'CSP_STRIPE_WEBHOOK_SECRET' => 'whsec_fixture')
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
  end
  teardown do
    %w[RUPERT_BILLING_ENABLED CSP_STRIPE_SECRET_KEY CSP_STRIPE_ACCOUNT_ID CSP_STRIPE_MONTHLY_PRICE_ID CSP_STRIPE_REFERRAL_COUPON_ID CSP_STRIPE_WEBHOOK_SECRET].each { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) }
    Current.reset
  end
  test 'signature rejects forged old and mutated payloads' do
    payload = '{"id":"evt_test"}'
    now = Time.current.to_i
    signature = OpenSSL::HMAC.hexdigest('SHA256', 'whsec_fixture', "#{now}.#{payload}")
    RupertBilling.verify_signature!(payload, "t=#{now},v1=bad,v1=#{signature}")
    assert_raises(RupertBilling::Error) { RupertBilling.verify_signature!(payload + ' ', "t=#{now},v1=#{signature}") }
    assert_raises(RupertBilling::Error) { RupertBilling.verify_signature!(payload, "t=#{now - 301},v1=#{signature}") }
  end
  test 'checkout requires consent and valid plan before provider calls' do
    RupertBilling.expects(:api).never
    assert_raises(RupertBilling::Error) { RupertBilling.checkout(tenant: @tenant, actor: @owner, plan: 'attacker', referral_code: nil, accepted: '1') }
    assert_raises(RupertBilling::Error) { RupertBilling.checkout(tenant: @tenant, actor: @owner, plan: 'monthly', referral_code: nil, accepted: nil) }
  end
  test 'referrals require another active paying workspace' do
    referrer = Tenant.create!(name: 'Referrer', subdomain: 'referrer-business')
    referral = CustomerReferral.create!(tenant: referrer, code: 'RUPERT-TEST')
    assert_nil CustomerReferral.eligible(referral.code, tenant: @tenant)
    sub = CustomerSubscription.create!(tenant: referrer, status: 'active')
    assert_equal referral, CustomerReferral.eligible(' rupert-test ', tenant: @tenant)
    assert_nil CustomerReferral.eligible(referral.code, tenant: referrer)
    sub.update!(status: 'past_due')
    assert_nil CustomerReferral.eligible(referral.code, tenant: @tenant)
  end
  test 'referral checkout sends server selected price coupon and commitment with idempotency' do
    referrer = Tenant.create!(name: 'Referrer', subdomain: 'referrer-checkout')
    CustomerSubscription.create!(tenant: referrer, status: 'active')
    CustomerReferral.create!(tenant: referrer, code: 'RUPERT-TEST')
    RupertBilling.stubs(:verify_configuration!)
    RupertBilling.expects(:api).with(:post, 'checkout/sessions', has_entries('mode' => 'subscription', 'line_items[0][price]' => 'price_monthly', 'discounts[0][coupon]' => 'coupon_year', 'subscription_data[metadata][referral_code]' => 'RUPERT-TEST'), idempotency: regexp_matches(/rupert-/)).once.returns({ 'id' => 'cs_test', 'url' => 'https://checkout.stripe.com/c/test' })
    2.times { assert_equal 'https://checkout.stripe.com/c/test', RupertBilling.checkout(tenant: @tenant, actor: @owner, plan: 'referral_year', referral_code: 'RUPERT-TEST', accepted: '1') }
    row = CustomerSubscription.find_by!(tenant: @tenant)
    assert_equal 'free', row.status
    assert row.commitment_accepted_at
    assert_nil row.stripe_subscription_id
  end
  test 'owner approved invitations allow only listed active customers without inventing a paid subscription' do
    previous = ENV['RUPERT_APPROVED_REFERRAL_CODES']
    ENV['RUPERT_APPROVED_REFERRAL_CODES'] = ' legacy-invite '
    referrer = Tenant.create!(name: 'Legacy customer', subdomain: 'legacy-customer')
    referral = CustomerReferral.create!(tenant: referrer, code: 'LEGACY-INVITE')
    assert_equal referral, CustomerReferral.eligible(' legacy-invite ', tenant: @tenant)
    assert_nil CustomerSubscription.find_by(tenant: referrer)
    assert_nil CustomerReferral.eligible(referral.code, tenant: referrer)
    other = Tenant.create!(name: 'Another customer', subdomain: 'another-customer')
    CustomerSubscription.create!(tenant: other, status: 'active')
    CustomerReferral.create!(tenant: other, code: 'OTHER-INVITE')
    assert_nil CustomerReferral.eligible('OTHER-INVITE', tenant: @tenant)
    referral.update!(active: false)
    assert_nil CustomerReferral.eligible(referral.code, tenant: @tenant)
    referral.update!(active: true)
    referrer.update!(status: 'suspended')
    assert_nil CustomerReferral.eligible(referral.code, tenant: @tenant)
  ensure
    previous.nil? ? ENV.delete('RUPERT_APPROVED_REFERRAL_CODES') : ENV['RUPERT_APPROVED_REFERRAL_CODES'] = previous
  end
  test 'webhook retrieves provider state and repeated old deliveries cannot restore status' do
    row = CustomerSubscription.create!(tenant: @tenant, stripe_subscription_id: 'sub_test', stripe_customer_id: 'cus_test', plan: 'monthly')
    event = { 'type' => 'customer.subscription.updated', 'livemode' => false, 'data' => { 'object' => { 'id' => 'sub_test', 'status' => 'active' } } }
    fresh = { 'customer' => 'cus_test', 'status' => 'past_due', 'metadata' => { 'rupert_tenant_id' => @tenant.id }, 'items' => { 'data' => [{ 'price' => { 'id' => 'price_monthly' }, 'quantity' => 1 }] } }
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_test').returns(fresh)
    2.times { RupertBilling.receive(event) }
    assert_equal 'past_due', row.reload.status
    fresh['metadata']['rupert_tenant_id'] = 'other-tenant'
    assert_raises(RupertBilling::Error) { RupertBilling.receive(event) }
    assert_equal 'past_due', row.reload.status
  end
  test 'configuration refuses another account and mispriced products' do
    RupertBilling.stubs(:api).with(:get, 'account').returns({ 'id' => 'acct_wrong' })
    assert_raises(RupertBilling::Error) { RupertBilling.verify_configuration! }
    RupertBilling.stubs(:api).with(:get, 'account').returns({ 'id' => 'acct_csp' })
    RupertBilling.stubs(:api).with(:get, 'prices/price_monthly').returns({ 'active' => true, 'currency' => 'usd', 'unit_amount' => 24950, 'recurring' => { 'interval' => 'month', 'interval_count' => 1 } })
    assert_raises(RupertBilling::Error) { RupertBilling.verify_configuration! }
  end
  test 'unsafe provider redirects are rejected' do
    %w[http://checkout.stripe.com/a https://checkout.stripe.com.evil.org/a https://user@checkout.stripe.com/a].each do |url|
      assert_raises(RupertBilling::Error) { RupertBilling.trusted_url!(url, 'checkout.stripe.com') }
    end
  end
  test 'an expired local checkout cannot create a duplicate while Stripe confirmation is delayed' do
    RupertBilling.stubs(:verify_configuration!)
    CustomerSubscription.create!(tenant: @tenant, checkout_token: 'attempt', checkout_session_id: 'cs_old', checkout_expires_at: 1.minute.ago, plan: 'monthly')
    RupertBilling.expects(:api).with(:get, 'checkout/sessions/cs_old').returns({ 'status' => 'complete' })
    assert_raises(RupertBilling::Error) { RupertBilling.checkout(tenant: @tenant, actor: @owner, plan: 'monthly', referral_code: nil, accepted: '1') }
  end
  test 'unknown checkout bindings are retried and never acknowledged as paid' do
    CustomerSubscription.create!(tenant: @tenant, checkout_token: 'pending')
    event = { 'type' => 'checkout.session.completed', 'livemode' => false, 'data' => { 'object' => { 'id' => 'cs_pending', 'client_reference_id' => @tenant.id } } }
    assert_raises(RupertBilling::Error) { RupertBilling.receive(event) }
    assert_equal 'free', CustomerSubscription.find_by!(tenant: @tenant).status
  end
  test 'support reasons are encrypted in stored rows' do
    operator = User.create!(tenant: @tenant, email: 'encryption-support@example.com', password: 'password123', role: 'super_admin')
    grant = SupportAccessGrant.create!(tenant: @tenant, granted_by: @owner, support_user: operator, reason: 'Private inventory issue', expires_at: 1.hour.from_now)
    raw = SupportAccessGrant.connection.select_value("SELECT reason FROM support_access_grants WHERE id = #{grant.id.to_i}")
    refute_includes raw, 'Private inventory issue'
    assert_equal 'Private inventory issue', grant.reload.reason
  end
end
