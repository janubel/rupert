# frozen_string_literal: true

require 'test_helper'

class BuzzAgentTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    BuzzAgent.generate_keypair!
    EnvStore.set('BUZZ_RELAY_URL', 'wss://relay.test')
    EnvStore.set('BUZZ_CHANNEL', 'channel-id-123')
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('BUZZ_RELAY_URL', nil)
    EnvStore.set('BUZZ_PRIVATE_KEY', nil)
    EnvStore.set('BUZZ_CHANNEL', nil)
  end

  test 'generate_keypair stores a private key and exposes the agent npub' do
    assert_equal 64, BuzzAgent.private_key_hex.length
    assert_match(/\Anpub1/, BuzzAgent.agent_npub)
  end

  test 'build_event signs a valid channel message with the channel tag' do
    event = BuzzAgent.build_event(content: 'hello', channel: 'channel-id-123')
    assert_equal 9, event.kind
    assert_includes event.tags, %w[h channel-id-123]
    assert event.verify_signature
    assert_equal BuzzAgent.public_key.to_s, event.pubkey.to_s
  end

  test 'build_event defaults to a text note without a channel' do
    event = BuzzAgent.build_event(content: 'hello')
    assert_equal 1, event.kind
    assert event.verify_signature
  end

  test 'notify returns an error when not configured' do
    EnvStore.set('BUZZ_PRIVATE_KEY', nil)
    ok, message = BuzzAgent.notify('hi')
    refute ok
    assert_match(/not configured/, message)
  end

  test 'publish sends the signed event and returns ok' do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    sent = nil
    fake.define_singleton_method(:send) do |data|
      sent = data
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], true, ''].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: 'hi', channel: 'c'))
    assert ok
    assert_includes sent, 'EVENT'
    assert_equal 'OK', message
  end

  test 'publish returns the relay rejection' do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], false, 'rate limited'].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: 'hi'))
    refute ok
    assert_equal 'rate limited', message
  end

  test 'publish returns an error when the relay cannot be reached' do
    WebSocket::Client::Simple.stubs(:connect).raises(StandardError, 'connection refused')
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: 'hi'))
    refute ok
    assert_equal 'connection refused', message
  end

  test 'register publishes a kind 0 profile event' do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    sent = nil
    fake.define_singleton_method(:send) do |data|
      sent = data
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], true, ''].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, = BuzzAgent.register!
    assert ok
    event = JSON.parse(sent)[1]
    assert_equal 0, event['kind']
    assert_match(/"name":"Rupert"/, event['content'])
  end

  test 'publish answers a NIP-42 auth challenge before the event' do
    fake = Object.new
    handlers = {}
    sent = []
    events_sent = 0
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      sent << data
      payload = JSON.parse(data)
      if payload[0] == 'AUTH'
        handlers[:message]&.call(Struct.new(:data).new(['OK', 'auth-event-id', true, ''].to_json))
      elsif (events_sent += 1) == 1
        handlers[:message]&.call(Struct.new(:data).new(%w[AUTH challenge-xyz].to_json))
      else
        handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], true, ''].to_json))
      end
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, = BuzzAgent.publish(BuzzAgent.build_event(content: 'hi'))
    assert ok
    auth = sent.find { |m| JSON.parse(m)[0] == 'AUTH' }
    auth_event = JSON.parse(auth)[1]
    assert_equal 22_242, auth_event['kind']
    assert_includes auth_event['tags'], %w[challenge challenge-xyz]
  end

  test 'publish waits for the relay to acknowledge the event, not the AUTH reply' do
    fake = Object.new
    handlers = {}
    order = []
    challenged = false
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      payload = JSON.parse(data)
      if payload[0] == 'AUTH'
        order << :auth_ok
        handlers[:message]&.call(Struct.new(:data).new(['OK', 'auth-event-id', true, ''].to_json))
      elsif !challenged
        challenged = true
        handlers[:message]&.call(Struct.new(:data).new(%w[AUTH challenge-xyz].to_json))
      else
        Thread.new do
          sleep 0.3
          order << :event_ok
          handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], true, ''].to_json))
        end
      end
    end
    fake.define_singleton_method(:close) { order << :close }

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, = BuzzAgent.publish(BuzzAgent.build_event(content: 'hi'))
    assert ok
    assert_equal :close, order.last, "closed before the event was acknowledged: #{order.inspect}"
    assert_includes order, :event_ok
  end

  test 'build_auth_event signs a valid NIP-42 event with challenge tag' do
    event = BuzzAgent.build_auth_event('challenge-xyz')
    assert_equal 22_242, event.kind
    assert_includes event.tags, ['relay', 'wss://relay.test']
    assert_includes event.tags, %w[challenge challenge-xyz]
    assert event.verify_signature
  end

  test 'check_status reports not configured without probing' do
    EnvStore.set('BUZZ_PRIVATE_KEY', nil)
    BuzzAgent.expects(:probe_relay).never
    status = BuzzAgent.check_status
    refute status[:configured]
    assert_nil status[:relay_reachable]
  end

  test 'check_status records the probe result and exposes it as last_status' do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    BuzzAgent.expects(:probe_relay).returns([true, false])
    status = BuzzAgent.check_status
    assert status[:relay_reachable]
    assert_equal false, status[:registered]
    assert_equal false, BuzzAgent.last_status[:registered]
  end

  test 'probe_relay reports an unreachable relay without raising' do
    WebSocket::Client::Simple.stubs(:connect).raises(Errno::ECONNREFUSED)
    assert_equal [false, nil], BuzzAgent.probe_relay
  end
end
