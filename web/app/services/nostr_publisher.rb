# frozen_string_literal: true

require 'json'
require 'timeout'

# Generic Nostr publisher: opens a WebSocket to a relay, authenticates with
# NIP-42, publishes a signed event, and waits for the OK acknowledgement.
# Shared by the Buzz agents. Note: the WS message callback runs with `self`
# set to the WebSocket client, so module methods are invoked explicitly.
module NostrPublisher
  def self.publish(relay:, private_key:, public_key:, event:)
    require 'websocket-client-simple'

    ack = nil
    authed = false
    sent_event = false
    event_id = event.id.to_s
    ws = WebSocket::Client::Simple.connect(relay)

    ws.on(:message) do |m|
      if m.respond_to?(:type) && m.type == :ping
        ws.send(m.data.to_s, type: :pong)
        next
      end
      next if m.respond_to?(:type) && m.type != :text

      data = JSON.parse(m.data.to_s)
      case data[0]
      when 'AUTH'
        unless authed
          authed = true
          auth = NostrPublisher.build_auth_event(relay, data[1], private_key, public_key)
          ws.send(['AUTH', auth.to_h].to_json)
          ws.send(['EVENT', event.to_h].to_json) if sent_event
        end
      when 'OK'
        # The relay also acknowledges our NIP-42 AUTH event with an OK; only the
        # answer to this event counts, or we close before it is stored.
        ack = data if data[1].to_s == event_id
      end
    rescue StandardError
      nil
    end
    ws.on(:error) { |e| ack ||= ['ERROR', e.message.to_s[0, 200]] }

    Timeout.timeout(8) { sleep 0.05 until ws.open? || ack }
    raise "could not connect to #{relay}" if ack.nil? && !ws.open?

    # Buzz challenges immediately on connect — wait for the auth round-trip
    # (with a generous fallback for relays that don't challenge) so the EVENT
    # is published as an authenticated session.
    deadline = Time.now + 5.0
    sleep 0.05 until authed || Time.now > deadline

    sent_event = true
    ws.send(['EVENT', event.to_h].to_json)
    begin
      Timeout.timeout(8) { sleep 0.05 until ack }
    rescue Timeout::Error
      nil
    end

    # If the first attempt was rejected (e.g. a late AUTH challenge raced our
    # send), the handler re-sends the EVENT after authenticating — wait briefly
    # for that acknowledgement before giving up.
    if ack && ack[2] != true
      begin
        Timeout.timeout(4) { sleep 0.05 until ack && ack[2] == true }
      rescue Timeout::Error
        nil
      end
    end

    ok = ack && ack[2] == true
    ok ? [true, ack[3].presence || 'OK'] : [false, (ack && ack[3]).presence || 'no acknowledgement from relay']
  rescue StandardError => e
    [false, e.message.to_s[0, 200]]
  ensure
    begin
      ws&.close
    rescue StandardError
      nil
    end
  end

  def self.build_event(private_key:, public_key:, kind:, content:, tags: [])
    event = Nostr::Event.new(pubkey: public_key, kind: kind, content: content.to_s, tags: tags)
    event.sign(private_key)
    event
  end

  # NIP-42 auth response: signed kind 22242 event echoing the challenge.
  def self.build_auth_event(relay, challenge, private_key, public_key)
    event = Nostr::Event.new(pubkey: public_key, kind: 22_242, content: '',
      tags: [['relay', relay], ['challenge', challenge.to_s]])
    event.sign(private_key)
    event
  end
end
