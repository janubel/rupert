# frozen_string_literal: true

require 'test_helper'

class GoogleOauthIdentityTest < ActiveSupport::TestCase
  test 'userinfo accepts a verified Google identity' do
    profile = { email: 'worker@approved.example', email_verified: true, sub: 'google-subject-123' }
    stub_request(:get, 'https://openidconnect.googleapis.com/v1/userinfo')
      .with(headers: { Authorization: 'Bearer test-token' }).to_return(status: 200, body: profile.to_json)

    assert_equal profile.stringify_keys, GoogleOauthService.userinfo('test-token')
  end

  test 'unverified or incomplete profiles cannot authenticate an allowed email domain' do
    [false, nil].each do |verified|
      stub_request(:get, 'https://openidconnect.googleapis.com/v1/userinfo')
        .to_return(status: 200, body: { email: 'worker@approved.example', email_verified: verified, sub: 'subject' }.to_json)
      assert_raises(GoogleOauthService::ExchangeError) { GoogleOauthService.userinfo('test-token') }
    end
    stub_request(:get, 'https://openidconnect.googleapis.com/v1/userinfo')
      .to_return(status: 200, body: { email: 'worker@approved.example', email_verified: true }.to_json)
    assert_raises(GoogleOauthService::ExchangeError) { GoogleOauthService.userinfo('test-token') }
  end
end
