# frozen_string_literal: true

require 'net/http'
require 'json'
require 'openssl'

# All credentials belong to the CSP billing account; never read tenant settings.
class RupertBilling
  class Error < StandardError; end
  TERMS_VERSION = '2026-10-20'
  def self.configured?
    %w[CSP_STRIPE_SECRET_KEY CSP_STRIPE_ACCOUNT_ID CSP_STRIPE_MONTHLY_PRICE_ID CSP_STRIPE_REFERRAL_COUPON_ID CSP_STRIPE_WEBHOOK_SECRET].all? { |key| ENV[key].present? } && ENV['RUPERT_BILLING_ENABLED'] == 'true'
  end

  def self.api(method, path, fields = {}, idempotency: nil)
    raise Error, 'Billing is not configured yet. Your free account remains available.' unless configured?
    uri = URI("https://api.stripe.com/v1/#{path}")
    req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    req.basic_auth(ENV.fetch('CSP_STRIPE_SECRET_KEY'), '')
    req['Stripe-Version'] = '2025-06-30.basil'
    req['Idempotency-Key'] = idempotency if idempotency
    req.set_form_data(fields) unless method == :get
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) { |http| http.request(req) }
    raise Error, 'Stripe could not complete this request. Please try again.' unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue Timeout::Error, SocketError, IOError, JSON::ParserError, SystemCallError
    raise Error, 'Billing is temporarily unavailable. Please try again.'
  end

  def self.verify_configuration!
    account = api(:get, 'account')
    raise Error, 'The billing account does not match the configured CSP account.' unless account['id'] == ENV.fetch('CSP_STRIPE_ACCOUNT_ID')
    price = api(:get, "prices/#{ENV.fetch('CSP_STRIPE_MONTHLY_PRICE_ID')}")
    unless price['active'] && price['currency'] == 'usd' && price['unit_amount'] == 49900 && price.dig('recurring', 'interval') == 'month' && price.dig('recurring', 'interval_count') == 1
      raise Error, 'The Rupert monthly price must be USD 499.00 per month.'
    end
    coupon = api(:get, "coupons/#{ENV.fetch('CSP_STRIPE_REFERRAL_COUPON_ID')}")
    products = coupon.dig('applies_to', 'products')
    unless coupon['valid'] && coupon['percent_off'] == 50 && coupon['duration'] == 'repeating' && coupon['duration_in_months'] == 12 && (!products || products.include?(price['product']))
      raise Error, 'The referral coupon must provide 50% off for 12 months on Rupert.'
    end
  end

  def self.checkout(tenant:, actor:, plan:, referral_code:, accepted:)
    raise Error, 'Choose a valid plan.' unless %w[monthly referral_year].include?(plan)
    raise Error, 'Accept the subscription terms before continuing.' unless accepted == '1'
    verify_configuration!
    subscription = CustomerSubscription.find_or_create_by!(tenant: tenant)
    referral = CustomerReferral.eligible(referral_code, tenant: tenant) if plan == 'referral_year'
    raise Error, 'Enter a referral code from an active Rupert customer.' if plan == 'referral_year' && !referral
    subscription.with_lock do
      raise Error, 'This workspace already has a subscription. Manage it through billing.' if subscription.stripe_subscription_id.present?
      if subscription.checkout_expires_at && subscription.checkout_expires_at > Time.current
        raise Error, 'A checkout is already open for a different plan. Finish it or wait one hour.' unless subscription.plan == plan && subscription.referral_code == referral&.code
      else
        if subscription.checkout_token.present?
          raise Error, 'The previous checkout needs reconciliation. Contact support before starting another.' if subscription.checkout_session_id.blank?
          previous = api(:get, "checkout/sessions/#{subscription.checkout_session_id}")
          raise Error, 'Your previous checkout is awaiting confirmation. Please contact support.' unless previous['status'] == 'expired'
        end
        subscription.assign_attributes(checkout_token: SecureRandom.uuid, checkout_url: nil, checkout_session_id: nil,
          checkout_expires_at: 1.hour.from_now, plan: plan, referral_code: referral&.code,
          commitment_accepted_at: Time.current, terms_version: TERMS_VERSION)
        subscription.save!
      end
    end
    return subscription.checkout_url if subscription.checkout_url.present?
    # Canonical configured origin, never an untrusted Host header.
    origin = ENV.fetch('RUPERT_PUBLIC_ORIGIN', 'https://rupertpos.com')
    raise Error, 'An HTTPS public origin is required.' unless origin.match?(%r{\Ahttps://[a-z0-9.-]+(?::[0-9]+)?\z}i)
    fields = { 'mode' => 'subscription', 'line_items[0][price]' => ENV.fetch('CSP_STRIPE_MONTHLY_PRICE_ID'),
      'line_items[0][quantity]' => '1', 'client_reference_id' => tenant.id, 'customer_email' => actor.email,
      'success_url' => "#{origin}/billing?checkout=returned", 'cancel_url' => "#{origin}/billing",
      'expires_at' => subscription.checkout_expires_at.to_i.to_s,
      'subscription_data[metadata][rupert_tenant_id]' => tenant.id,
      'subscription_data[metadata][rupert_plan]' => plan,
      'subscription_data[metadata][terms_version]' => TERMS_VERSION,
      'custom_text[submit][message]' => plan == 'referral_year' ? 'USD 249.50/month for 12 months (USD 2,994 total commitment), then USD 499/month. Taxes may apply. Billed by CSP Cyber Security Pilot.' : 'USD 499/month. Taxes may apply. Billed by CSP Cyber Security Pilot.' }
    if referral
      fields['discounts[0][coupon]'] = ENV.fetch('CSP_STRIPE_REFERRAL_COUPON_ID')
      fields['subscription_data[metadata][referral_code]'] = referral.code
    end
    result = api(:post, 'checkout/sessions', fields, idempotency: "rupert-#{tenant.id}-#{subscription.checkout_token}")
    url = trusted_url!(result['url'], 'checkout.stripe.com')
    subscription.update!(checkout_session_id: result.fetch('id'), checkout_url: url)
    url
  end

  def self.trusted_url!(url, host)
    uri = URI.parse(url.to_s)
    raise Error, 'Stripe returned an invalid destination.' unless uri.scheme == 'https' && uri.host == host && uri.userinfo.nil?
    url
  rescue URI::InvalidURIError
    raise Error, 'Stripe returned an invalid destination.'
  end

  def self.verify_signature!(payload, signature)
    raise Error, 'Webhook not configured.' unless configured?
    parts = signature.to_s.split(',').map { |part| part.split('=', 2) }
    timestamp = parts.find { |key, _| key == 't' }&.last.to_s
    raise Error, 'Invalid webhook signature.' unless timestamp.match?(/\A[0-9]+\z/) && (Time.current.to_i - timestamp.to_i).abs <= 300
    digest = OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('CSP_STRIPE_WEBHOOK_SECRET'), "#{timestamp}.#{payload}")
    valid = parts.any? { |key, value| key == 'v1' && value && ActiveSupport::SecurityUtils.secure_compare(digest, value) }
    raise Error, 'Invalid webhook signature.' unless valid
  end

  def self.receive(event)
    expected_live = ENV['CSP_STRIPE_SECRET_KEY'].to_s.start_with?('sk_live_', 'rk_live_')
    raise Error, 'Webhook mode mismatch.' unless event['livemode'] == expected_live
    object = event.dig('data', 'object') || {}
    if event['type'] == 'checkout.session.completed'
      row = CustomerSubscription.find_by(checkout_session_id: object['id'])
      if !row && CustomerSubscription.exists?(tenant_id: object['client_reference_id'])
        raise Error, 'Checkout binding is not ready; retry this delivery.'
      end
      return unless row
      session = api(:get, "checkout/sessions/#{row.checkout_session_id}")
      raise Error, 'Checkout workspace mismatch.' unless session['client_reference_id'] == row.tenant_id && session['mode'] == 'subscription' && session['status'] == 'complete'
      subscription_id = session.fetch('subscription')
    elsif %w[customer.subscription.updated customer.subscription.deleted invoice.paid invoice.payment_failed].include?(event['type'])
      subscription_id = event['type'].start_with?('customer.subscription.') ? object['id'] : object.dig('parent', 'subscription_details', 'subscription')
      return if subscription_id.blank?
      row = CustomerSubscription.find_by(stripe_subscription_id: subscription_id)
      return unless row
    else
      return
    end
    row.with_lock do
      # Retrieve current provider state under the row lock: old deliveries cannot restore stale status.
      fresh = api(:get, "subscriptions/#{subscription_id}")
      raise Error, 'Subscription workspace mismatch.' unless fresh.dig('metadata', 'rupert_tenant_id') == row.tenant_id
      items = fresh.dig('items', 'data') || []
      raise Error, 'Unexpected subscription price.' unless items.one? && items.first.dig('price', 'id') == ENV.fetch('CSP_STRIPE_MONTHLY_PRICE_ID') && items.first['quantity'] == 1
      raise Error, 'Subscription customer mismatch.' if row.stripe_customer_id.present? && fresh['customer'] != row.stripe_customer_id
      raise Error, 'Subscription identity mismatch.' if row.stripe_subscription_id.present? && row.stripe_subscription_id != subscription_id
      row.update!(stripe_customer_id: fresh.fetch('customer'), stripe_subscription_id: subscription_id,
        status: fresh.fetch('status'), last_synced_at: Time.current,
        commitment_ends_at: row.plan == 'referral_year' ? Time.at(fresh.fetch('start_date')).utc.advance(months: 12) : nil)
    end
  end
end
