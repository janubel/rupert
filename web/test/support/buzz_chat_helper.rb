# frozen_string_literal: true

require_relative 'fake_buzz_relay'

# Starts the in-process Buzz relay and points Rupert's Buzz settings at it.
module BuzzChatHelper
  CHANNEL = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'

  def start_buzz_relay(**options)
    Current.tenant = tenants(:default_tenant)
    BuzzAgent.generate_keypair!
    @relay = FakeBuzzRelay.new(channel: CHANNEL, **options).start
    EnvStore.set('BUZZ_RELAY_URL', @relay.url)
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    @alice = FakeBuzzRelay.keypair
    @bob = FakeBuzzRelay.keypair
    @relay
  end

  def stop_buzz_relay
    @relay&.stop
    %w[BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_PRIVATE_KEY BUZZ_MEMBER_NAMES FEEDBACK_READY_SENDERS].each { |key| EnvStore.set(key, nil) }
    Current.reset
  end

  # The Rupert agent as a keypair the relay helpers can sign with.
  def agent_key
    { private_key: BuzzAgent.private_key, public_key: BuzzAgent.public_key_hex }
  end
end
