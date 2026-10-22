# frozen_string_literal: true

# A Rupert person's own Buzz (Nostr) key. The WebUI Buzz client signs that
# person's messages, profile and typing indicators with it, so the relay, the
# Buzz apps and the @rupert agent see a separate person, not "X via Rupert".
#
# The private key is generated here, encrypted at rest and never shown or
# logged. The relay is closed: a new identity can read and post only after an
# operator adds its public key to the relay and its channels
# (deploy/ser8/buzz/add-member.sh). The page shows the npub to pass on.
class BuzzPersonKey < ApplicationRecord
  include TenantScoped

  belongs_to :user

  encrypts :private_key

  validates :pubkey, presence: true, format: { with: /\A\h{64}\z/ }
  validates :private_key, presence: true

  # The person's identity, created on first use.
  def self.for(user)
    find_by(user_id: user.id) || create_for!(user)
  rescue ActiveRecord::RecordNotUnique
    find_by!(user_id: user.id)
  end

  def self.create_for!(user)
    pair = Nostr::Keygen.new.generate_key_pair
    create!(user: user, pubkey: Nostr::Keygen.new.extract_public_key(Nostr::PrivateKey.new(pair.private_key)).to_s,
      private_key: pair.private_key.to_s)
  end

  def npub = Nostr::PublicKey.new(pubkey).to_bech32

  def build_event(kind:, content:, tags: [])
    event = Nostr::Event.new(pubkey: nostr_public_key, kind: kind, content: content.to_s, tags: tags)
    event.sign(nostr_private_key)
    event
  end

  # NIP-42 answer to the relay's challenge, signed as this person.
  def build_auth_event(challenge, relay:)
    build_event(kind: 22_242, content: '', tags: [['relay', relay], ['challenge', challenge.to_s]])
  end

  # Kind 0 profile so Buzz apps show the person's name, not a key.
  def profile_event(name)
    build_event(kind: 0, content: { name: name, display_name: name }.to_json)
  end

  private

  def nostr_private_key = Nostr::PrivateKey.new(private_key)
  def nostr_public_key = Nostr::PublicKey.new(pubkey)
end
