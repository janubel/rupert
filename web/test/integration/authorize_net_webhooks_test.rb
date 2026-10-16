# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetWebhooksTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = PosConnection.create!(provider: 'authorize_net_reporting', environment: 'sandbox', account_reference: '12345',
      vendor_approved: true, reporting_enabled: true,
      credentials_json: { api_login_id: 'synthetic', transaction_key: 'synthetic-key', signature_key: 'a1' * 64 }.to_json)
    @path = authorize_net_webhook_path(connection_id: @connection.id)
    @event = { notificationId: SecureRandom.uuid, eventType: 'net.authorize.payment.authcapture.created',
      payload: { entityName: 'transaction', id: '9001', authAmount: 999999 } }
  end

  teardown { Current.reset }

  test 'signed callback works without a session and queues only scoped identity' do
    assert_enqueued_with(job: AuthorizeNetEventJob, args: [{ tenant_id: @connection.tenant_id,
      connection_id: @connection.id, webhook_scope: @connection.webhook_scope, transaction_id: '9001' }]) { deliver }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 0, AuthorizeNetTransaction.count
    assert_equal 0, Core::Order.count
  end

  test 'bad signatures wrong keys and modified bytes never enqueue' do
    assert_no_enqueued_jobs { deliver(signature: 'sha512=' + '0' * 128) }
    assert_response :unauthorized
    signed_body = @event.to_json
    hash = OpenSSL::HMAC.hexdigest('SHA512', 'a1' * 64, signed_body)
    assert_no_enqueued_jobs { deliver(body: signed_body + ' ', signature: 'sha512=' + hash) }
    assert_response :unauthorized
  end

  test 'unconfigured paused and inactive accounts reject callbacks' do
    @connection.update!(reporting_enabled: false)
    assert_no_enqueued_jobs { deliver }
    assert_response :not_found
    @connection.update!(reporting_enabled: true)
    tenants(:default_tenant).update!(status: 'suspended')
    assert_no_enqueued_jobs { deliver }
    assert_response :not_found
  end

  test 'malformed signed event invalid id and oversized body are rejected' do
    assert_no_enqueued_jobs { deliver(body: '{', content_type: 'text/plain') }
    assert_response :bad_request
    @event[:payload][:id] = 'bogus'
    assert_no_enqueued_jobs { deliver }
    assert_response :bad_request
    assert_no_enqueued_jobs { deliver(body: @event.to_json + ' ' * 32_769) }
    assert_response :content_too_large
  end

  test 'event job rejects a replaced account or key but accepts ordinary import status changes' do
    scope = @connection.webhook_scope
    @connection.update!(last_report_status: 'complete', last_reported_at: Time.current)
    AuthorizeNetReporting::Import.expects(:call).with(connection: @connection, transaction_id: '9001').once
    AuthorizeNetEventJob.perform_now(tenant_id: @connection.tenant_id, connection_id: @connection.id, webhook_scope: scope, transaction_id: '9001')
    @connection.update!(account_reference: '67890')
    AuthorizeNetReporting::Import.expects(:call).never
    AuthorizeNetEventJob.perform_now(tenant_id: @connection.tenant_id, connection_id: @connection.id, webhook_scope: scope, transaction_id: '9001')
  end

  private

  def deliver(body: @event.to_json, signature: nil, content_type: 'application/json')
    signature ||= 'sha512=' + OpenSSL::HMAC.hexdigest('SHA512', 'a1' * 64, body)
    post @path, params: body, headers: { 'Content-Type' => content_type, 'X-ANET-Signature' => signature }
  end
end
