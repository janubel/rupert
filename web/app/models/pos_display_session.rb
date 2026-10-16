# frozen_string_literal: true

require 'digest'

class PosDisplaySession < ApplicationRecord
  include TenantScoped
  belongs_to :user
  belongs_to :location
  encrypts :display_token
  serialize :draft_json, coder: JSON
  before_validation :create_token, on: :create
  validate do
    unless user&.tenant_id == tenant_id && location&.tenant_id == tenant_id && location.source == 'ctrax'
      errors.add(:base, 'Cashier and location must belong to this workspace.')
    end
  end

  def active?
    closed_at.nil? && expires_at > Time.current && tenant&.status == 'active' && user&.active? && %w[sales.read sales.write inventory.read].all? { |permission| user.can?(permission) }
  end

  def draft
    draft_json.is_a?(Hash) ? draft_json : {}
  end

  def confirmed?
    active? && chosen_tip_cents.present? && confirmed_revision == cart_revision
  end

  def subtotal_cents
    (BigDecimal(draft.fetch('subtotal', '0')) * 100).to_i
  end

  def publish!(quote)
    clean = quote.slice('source', 'currency_code', 'lines', 'subtotal', 'preview', 'tip_type', 'tip_amount', 'preview_total')
    digest = Digest::SHA256.hexdigest(JSON.generate(clean))
    with_lock do
      raise ActiveRecord::RecordInvalid, self unless active?
      return if draft_digest == digest

      update!(draft_json: clean, draft_digest: digest, cart_revision: cart_revision + 1,
        confirmed_revision: nil, chosen_tip_cents: nil)
    end
  end

  def choose_tip!(revision:, choice:, amount: nil)
    with_lock do
      return :expired unless active?
      return :invalid unless revision.to_s.match?(/\A[0-9]{1,10}\z/)
      return :changed unless cart_revision == revision.to_i && draft['lines'].is_a?(Array) && draft['lines'].any?

      return :confirmed if confirmed?

      cents = case choice
      when 'none' then 0
      when '10', '15', '20' then (BigDecimal(subtotal_cents.to_s) * choice.to_i / 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
      when 'custom'
        return :invalid unless amount.to_s.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/)

        (BigDecimal(amount) * 100).to_i
      else return :invalid
      end
      return :invalid unless cents.between?(0, 99_999_999)

      update!(chosen_tip_cents: cents, confirmed_revision: cart_revision)
      :confirmed
    end
  end

  def public_state
    { active: active?, demo: demo?, cart_revision: cart_revision, lines: draft['lines'] || [],
      subtotal_cents: subtotal_cents, currency: draft['currency_code'] || 'USD',
      confirmed: confirmed?, tip_cents: confirmed? ? chosen_tip_cents : nil }
  end

  private

  def create_token
    self.display_token ||= SecureRandom.urlsafe_base64(32)
    self.token_digest = Digest::SHA256.hexdigest(display_token)
    self.expires_at ||= 30.minutes.from_now
  end
end
