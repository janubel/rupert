# frozen_string_literal: true

require 'test_helper'

class BuzzCardTest < ActionDispatch::IntegrationTest
  CHANNEL = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown do
    %w[BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_PRIVATE_KEY BUZZ_DOWNLOAD_IOS].each { |key| EnvStore.set(key, nil) }
    Current.reset
  end

  def sign_in(role:, email: "#{role}-buzz@example.com")
    User.create!(tenant: @tenant, email: email, role: role, password: 'password123', name: 'Buzz Tester')
    post login_path, params: { email: email, password: 'password123' }
  end

  def configure_buzz
    BuzzAgent.generate_keypair!
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
  end

  test 'signed-out visitors are sent to sign in' do
    get buzz_path
    assert_redirected_to login_path
  end

  test 'employees cannot open the card and have no header entry' do
    sign_in(role: 'employee')
    get buzz_path
    assert_response :redirect
    refute_equal buzz_path, URI(response.location).path
    get time_clock_path
    assert_select "a[href='#{buzz_path}']", 0
  end

  test 'unconfigured Buzz shows a clear not-set-up state with the downloads still available' do
    sign_in(role: 'admin')
    get buzz_path
    assert_response :success
    assert_select 'h2', text: /Buzz is not set up yet/
    assert_select '[aria-disabled=true]', text: /Open chat/
    assert_select '#get-buzz a[href=?]', BuzzConnect::RELEASES_URL, minimum: 3
    assert_select '[data-controller=qr]', 0
    assert_select 'a[href=?]', settings_path(anchor: 'buzz')
  end

  test 'a manager without settings access is told to ask an administrator' do
    sign_in(role: 'manager')
    get buzz_path
    assert_response :success
    assert_includes response.body, 'Ask an administrator'
    assert_select 'a[href=?]', settings_path(anchor: 'buzz'), 0
  end

  test 'configured Buzz shows the profile, chat and download actions, connect details and a QR' do
    configure_buzz
    sign_in(role: 'admin')
    get buzz_path
    assert_response :success
    assert_select "a[href='buzz://channel/#{CHANNEL}']", text: /Open chat/
    assert_select "a[href='#get-buzz']", text: /Get Buzz/
    assert_select 'code', text: BuzzAgent.agent_npub
    assert_select 'code', text: 'wss://buzz.example.com'
    assert_select 'code', text: CHANNEL
    assert_select '[data-controller=qr][data-qr-text-value^=?]', 'buzz://add-community?relay='
    assert_select '[data-controller=copy]', minimum: 3
    assert_select 'h2', text: /not set up/, count: 0
  end

  test 'the page never contains the private key' do
    configure_buzz
    sign_in(role: 'admin')
    get buzz_path
    refute_includes response.body, BuzzAgent.private_key_hex
    refute_match(/nsec1[0-9a-z]{20,}/, response.body)
  end

  test 'configured download links are shown and unset mobile stores say not available' do
    configure_buzz
    EnvStore.set('BUZZ_DOWNLOAD_IOS', 'https://testflight.apple.com/join/example')
    sign_in(role: 'admin')
    get buzz_path
    assert_select 'a[href=?]', 'https://testflight.apple.com/join/example'
    assert_select 'li', text: /Android.*Not available yet/m
  end

  test 'the header has a Buzz entry for staff with dashboard access' do
    sign_in(role: 'admin')
    get dashboard_path
    assert_select "header a[href='#{buzz_path}'][aria-label='Buzz team chat']", 1
  end
end
