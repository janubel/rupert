# frozen_string_literal: true

require 'test_helper'

class BuzzConnectTest < ActiveSupport::TestCase
  CHANNEL = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'

  setup { Current.tenant = tenants(:default_tenant) }

  teardown do
    %w[BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_PRIVATE_KEY BUZZ_CHAT_LINK_TEMPLATE BUZZ_CONNECT_LINK_TEMPLATE
       BUZZ_DOWNLOAD_MACOS BUZZ_DOWNLOAD_IOS BUZZ_WEB_URL].each { |key| EnvStore.set(key, nil) }
    Current.tenant = nil
  end

  test 'nothing is configured by default' do
    assert_equal :unconfigured, BuzzConnect.state
    assert_nil BuzzConnect.chat_url
    assert_nil BuzzConnect.connect_url
    refute BuzzConnect.ready?
  end

  test 'a relay alone offers adding the workspace but no channel link' do
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    assert_equal :relay_only, BuzzConnect.state
    assert_equal BuzzConnect.connect_url, BuzzConnect.chat_url
    assert_match(%r{\Abuzz://add-community\?relay=wss%3A%2F%2Fbuzz\.example\.com&name=}, BuzzConnect.connect_url)
  end

  test 'relay and channel produce the documented buzz deep links' do
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    assert BuzzConnect.ready?
    assert_equal "buzz://channel/#{CHANNEL}", BuzzConnect.chat_url
    assert BuzzConnect.channel_looks_valid?
  end

  test 'a channel that is not a UUID is flagged' do
    EnvStore.set('BUZZ_CHANNEL', 'not-a-uuid')
    refute BuzzConnect.channel_looks_valid?
  end

  test 'link templates are configurable and values are URL-encoded' do
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    EnvStore.set('BUZZ_CHAT_LINK_TEMPLATE', 'https://chat.example.com/open?relay={relay}&c={channel}')
    assert_equal "https://chat.example.com/open?relay=wss%3A%2F%2Fbuzz.example.com&c=#{CHANNEL}", BuzzConnect.chat_url
  end

  test 'templates cannot produce script or other unsafe links' do
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    ['javascript:alert(1)', 'data:text/html,hi', 'http://insecure.example.com/{channel}', 'ftp://x/{channel}'].each do |template|
      EnvStore.set('BUZZ_CHAT_LINK_TEMPLATE', template)
      assert_nil BuzzConnect.chat_url, template
    end
  end

  test 'a relay that is not ws or wss, or carries credentials, is ignored' do
    ['https://buzz.example.com', 'wss://user:pass@buzz.example.com', 'not a url', 'javascript:alert(1)'].each do |value|
      EnvStore.set('BUZZ_RELAY_URL', value)
      assert_nil BuzzConnect.relay_url, value
      assert_equal :unconfigured, BuzzConnect.state
    end
  end

  test 'desktop downloads default to the Buzz releases page and mobile and web are unavailable' do
    platforms = BuzzConnect.platforms.index_by(&:key)
    assert_equal %w[macos windows linux ios android web], platforms.keys
    %w[macos windows linux].each { |key| assert_equal BuzzConnect::RELEASES_URL, platforms[key].url }
    %w[ios android web].each { |key| refute platforms[key].available?, key }
  end

  test 'download links are configurable and must be https' do
    EnvStore.set('BUZZ_DOWNLOAD_IOS', 'https://testflight.apple.com/join/example')
    EnvStore.set('BUZZ_DOWNLOAD_MACOS', 'javascript:alert(1)')
    EnvStore.set('BUZZ_WEB_URL', 'http://insecure.example.com')
    platforms = BuzzConnect.platforms.index_by(&:key)
    assert_equal 'https://testflight.apple.com/join/example', platforms['ios'].url
    assert_nil platforms['macos'].url
    assert_nil platforms['web'].url
  end

  test 'public info never includes the private key' do
    BuzzAgent.generate_keypair!
    EnvStore.set('BUZZ_RELAY_URL', 'wss://buzz.example.com')
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    exposed = [BuzzConnect.chat_url, BuzzConnect.connect_url, BuzzConnect.agent_npub,
               BuzzConnect.platforms.map(&:url)].flatten.join(' ')
    assert_match(/\Anpub1/, BuzzConnect.agent_npub)
    refute_includes exposed, BuzzAgent.private_key_hex
    refute_match(/nsec1/, exposed)
  end
end
