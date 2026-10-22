# frozen_string_literal: true

require 'test_helper'

class BuzzPersonKeyTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
  end

  teardown { Current.reset }

  test 'one key per person, created on first use and reused after' do
    key = BuzzPersonKey.for(@user)
    assert_match(/\A\h{64}\z/, key.pubkey)
    assert_equal key, BuzzPersonKey.for(@user)
    assert_match(/\Anpub1/, key.npub)
  end

  test 'the private key is encrypted at rest and never the public key' do
    key = BuzzPersonKey.for(@user)
    stored = BuzzPersonKey.connection.select_value("SELECT private_key FROM buzz_person_keys WHERE id = #{key.id}")
    assert_no_match(/\A\h{64}\z/, stored, 'stored value must be ciphertext, not the hex key')
    assert_not_equal key.pubkey, key.private_key
  end

  test 'events and the relay sign-in are signed by the person, not the agent' do
    key = BuzzPersonKey.for(@user)
    event = key.build_event(kind: 9, content: 'hi', tags: [%w[h channel]])
    assert event.verify_signature
    assert_equal key.pubkey, event.pubkey.to_s

    auth = key.build_auth_event('challenge-1', relay: 'wss://relay.test')
    assert_equal 22_242, auth.kind
    assert_includes auth.tags, %w[challenge challenge-1]
    assert auth.verify_signature

    profile = JSON.parse(key.profile_event('Sam').content)
    assert_equal 'Sam', profile['name']
  end
end
