# frozen_string_literal: true

require 'digest'
require 'securerandom'

# A Buzz public key that belongs to a Rupert person. It exists so the @rupert
# agent can answer someone as themselves; it never widens what they can see.
#
# Linking needs both sides: the person makes a code in Rupert, sends it to the
# agent in a direct message (the agent reads the key from the signed event, so
# it cannot be typed in), then confirms the key in Rupert. A key is trusted only
# while its person is still eligible (see .eligible?), checked on every use.
class BuzzIdentity < ApplicationRecord
  include TenantScoped

  STATUSES = %w[code pending active revoked].freeze
  CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'
  CODE_LENGTH = 8
  CODE_TTL = 10.minutes
  PUBKEY = /\A\h{64}\z/
  Result = Struct.new(:status, :identity, keyword_init: true) do
    def ok? = status == :ok
  end

  belongs_to :user

  validates :status, inclusion: { in: STATUSES }
  validates :pubkey, format: { with: PUBKEY }, allow_nil: true

  scope :live, -> { where(status: %w[pending active]) }
  scope :active, -> { where(status: 'active') }
  scope :waiting_for_confirmation, -> { where(status: 'pending') }
  scope :open_codes, -> { where(status: 'code').where(code_expires_at: Time.current..) }

  class << self
    # May this person be answered over Buzz? The same gate as the Ask Rupert
    # panel, applied again on every message.
    def eligible?(user)
      return false unless user&.active? && !user.employee? && user.can?('chat.use')

      tenant = user.tenant
      tenant&.status == 'active' && Current.tenant_id == user.tenant_id
    end

    # Makes a new code for the person (replacing any unused one). Returns [identity, code];
    # the code is shown once and only its digest is stored.
    def issue_code!(user)
      raise ArgumentError, 'not eligible' unless eligible?(user)

      transaction do
        where(user_id: user.id, status: 'code').update_all(status: 'revoked', revoked_at: Time.current)
        code = Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
        [create!(user: user, status: 'code', code_digest: digest(code), code_expires_at: CODE_TTL.from_now), code]
      end
    end

    # The agent has received `code` from `pubkey` (taken from a signed event, in a direct message).
    def claim(code:, pubkey:)
      return Result.new(status: :invalid) unless pubkey.to_s.match?(PUBKEY)

      row = find_by(status: 'code', code_digest: digest(code))
      return Result.new(status: :invalid) unless row
      return Result.new(status: :expired, identity: row) if row.code_expires_at.nil? || row.code_expires_at < Time.current
      return Result.new(status: :ineligible, identity: row) unless eligible?(row.user)
      return Result.new(status: :taken, identity: row) if live.where(pubkey: pubkey.to_s.downcase).exists?

      row.update!(status: 'pending', pubkey: pubkey.to_s.downcase, code_digest: nil, claimed_at: Time.current)
      Result.new(status: :ok, identity: row)
    end

    # A code that was posted where others could read it must never work.
    def burn(code)
      where(status: 'code', code_digest: digest(code)).update_all(status: 'revoked', revoked_at: Time.current)
    end

    # The active link for a key, or nil. A link counts only while its person is still eligible.
    def lookup(pubkey)
      return nil unless pubkey.to_s.match?(PUBKEY)

      row = active.includes(:user).find_by(pubkey: pubkey.to_s.downcase)
      return nil unless row && eligible?(row.user)

      row.touch_used!
      row
    end

    def user_for(pubkey) = lookup(pubkey)&.user

    def normalize(code)
      code.to_s.upcase.gsub(/[^A-Z0-9]/, '')
    end

    def digest(code)
      Digest::SHA256.hexdigest("buzz-link:#{Current.tenant_id}:#{normalize(code)}")
    end
  end

  def pending? = status == 'pending'
  def active? = status == 'active'

  # Short form of the key people can compare with their Buzz app.
  def fingerprint
    pubkey.to_s.scan(/.{1,4}/).first(4).join(' ')
  end

  def npub
    Nostr::PublicKey.new(pubkey).to_bech32
  rescue StandardError
    nil
  end

  def confirm!
    return false unless pending? && self.class.eligible?(user)

    update!(status: 'active', linked_at: Time.current)
  end

  def revoke!
    update!(status: 'revoked', revoked_at: Time.current)
  end

  def touch_used!
    return if last_used_at && last_used_at > 1.minute.ago

    update_columns(last_used_at: Time.current)
  end
end
