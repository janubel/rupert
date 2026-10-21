# frozen_string_literal: true

require 'test_helper'

class NostrPublisherTest < ActiveSupport::TestCase
  setup do
    pair = Nostr::Keygen.new.generate_key_pair
    @private_key = Nostr::PrivateKey.new(pair.private_key)
    @public_key = Nostr::PublicKey.new(Nostr::Keygen.new.extract_public_key(@private_key))
    @event = NostrPublisher.build_event(private_key: @private_key, public_key: @public_key, kind: 9, content: 'hi', tags: [%w[h c]])
  end

  def publish
    NostrPublisher.publish(relay: 'wss://relay.test', private_key: @private_key, public_key: @public_key, event: @event)
  end

  test 'publish returns ok once the relay acknowledges the event' do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], true, ''].to_json)) if payload[0] == 'EVENT'
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = publish
    assert ok
    assert_equal 'OK', message
  end

  test 'publish waits for the event acknowledgement, not the AUTH reply' do
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
    ok, = publish
    assert ok
    assert_includes order, :event_ok, "closed before the event was acknowledged: #{order.inspect}"
    assert_equal :close, order.last
  end

  test 'publish reports the relay rejection' do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(['OK', payload[1]['id'], false, 'blocked: not a member'].to_json)) if payload[0] == 'EVENT'
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = publish
    refute ok
    assert_equal 'blocked: not a member', message
  end
end
