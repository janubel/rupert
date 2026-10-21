# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

class BuzzIdentityTest < ActiveSupport::TestCase
  include AskRupertHelper

  setup do
    @user = person('admin')
    Current.user = @user
    @key = SecureRandom.hex(32)
  end

  teardown { Current.reset }

  def linked(user = @user, key = @key)
    _, code = BuzzIdentity.issue_code!(user)
    identity = BuzzIdentity.claim(code: code, pubkey: key).identity
    identity.confirm!
    identity
  end

  test 'a code is shown once and only its digest is kept' do
    row, code = BuzzIdentity.issue_code!(@user)
    assert_match(/\A[2-9A-HJKMNP-Z]{8}\z/, code)
    assert_not_includes row.attributes.values.map(&:to_s), code
    assert_equal BuzzIdentity.digest(code), row.code_digest
    assert_equal BuzzIdentity.digest(code.downcase.insert(4, '-')), row.code_digest, 'spacing, dashes and case do not matter'
  end

  test 'a new code replaces the unused one' do
    _, first = BuzzIdentity.issue_code!(@user)
    _, second = BuzzIdentity.issue_code!(@user)
    assert_equal :invalid, BuzzIdentity.claim(code: first, pubkey: @key).status
    assert BuzzIdentity.claim(code: second, pubkey: @key).ok?
  end

  test 'only people who may use Ask Rupert can make a code' do
    assert_raises(ArgumentError) { BuzzIdentity.issue_code!(person('cashier')) }
    assert_raises(ArgumentError) { BuzzIdentity.issue_code!(person('employee')) }
  end

  test 'claiming a code makes a pending link that grants nothing until it is confirmed' do
    _, code = BuzzIdentity.issue_code!(@user)
    result = BuzzIdentity.claim(code: code, pubkey: @key.upcase)
    assert result.ok?
    assert_equal 'pending', result.identity.status
    assert_equal @key, result.identity.pubkey
    assert_nil BuzzIdentity.lookup(@key)
    assert result.identity.confirm!
    assert_equal @user, BuzzIdentity.user_for(@key)
  end

  test 'a code works once' do
    _, code = BuzzIdentity.issue_code!(@user)
    assert BuzzIdentity.claim(code: code, pubkey: @key).ok?
    assert_equal :invalid, BuzzIdentity.claim(code: code, pubkey: SecureRandom.hex(32)).status
  end

  test 'an expired code is refused' do
    row, code = BuzzIdentity.issue_code!(@user)
    row.update!(code_expires_at: 1.minute.ago)
    assert_equal :expired, BuzzIdentity.claim(code: code, pubkey: @key).status
  end

  test 'a key that is not a 64 character hex key is refused' do
    _, code = BuzzIdentity.issue_code!(@user)
    assert_equal :invalid, BuzzIdentity.claim(code: code, pubkey: 'npub1abc').status
    assert_nil BuzzIdentity.lookup('not-a-key')
  end

  test 'a key already linked to someone cannot be claimed by another person' do
    linked
    other = person('admin')
    _, code = BuzzIdentity.issue_code!(other)
    assert_equal :taken, BuzzIdentity.claim(code: code, pubkey: @key).status
    assert_equal @user, BuzzIdentity.user_for(@key)
  end

  test 'a code posted in the open can be burned' do
    _, code = BuzzIdentity.issue_code!(@user)
    BuzzIdentity.burn(code)
    assert_equal :invalid, BuzzIdentity.claim(code: code, pubkey: @key).status
  end

  test 'a link stops working the moment its person is no longer eligible' do
    linked
    assert BuzzIdentity.lookup(@key)
    @user.update!(active: false)
    assert_nil BuzzIdentity.lookup(@key), 'deactivated'
    @user.update!(active: true)
    assert BuzzIdentity.lookup(@key)
    @user.update!(role: 'cashier')
    assert_nil BuzzIdentity.lookup(@key), 'lost the Rupert Chat permission'
  end

  test 'a removed link no longer counts and frees the key' do
    linked.revoke!
    assert_nil BuzzIdentity.lookup(@key)
    other = person('admin')
    _, code = BuzzIdentity.issue_code!(other)
    assert BuzzIdentity.claim(code: code, pubkey: @key).ok?
  end

  test 'a code cannot be claimed after its person loses access' do
    _, code = BuzzIdentity.issue_code!(@user)
    @user.update!(role: 'cashier')
    assert_equal :ineligible, BuzzIdentity.claim(code: code, pubkey: @key).status
  end

  test 'links stay inside their workspace' do
    linked
    Current.tenant = Tenant.create!(name: 'Other Buzz tenant', subdomain: "other-buzz-#{SecureRandom.hex(3)}")
    assert_nil BuzzIdentity.lookup(@key)
    assert_empty BuzzIdentity.all
  end
end
