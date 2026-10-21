# frozen_string_literal: true

# When Rupert last asked the Buzz relay for the Team chat, and whether it worked.
class BuzzChatState < ApplicationRecord
  include TenantScoped

  # The chat page asks every few seconds; the relay is called at most this often.
  MIN_INTERVAL = 6.seconds

  def self.current
    find_by(tenant_id: Current.tenant_id) || create!
  rescue ActiveRecord::RecordNotUnique
    find_by!(tenant_id: Current.tenant_id)
  end

  # True for exactly one caller per interval, however many pages are polling.
  def self.claim_attempt!(now: Time.current)
    state = current
    claimed = where(id: state.id)
              .where('last_attempt_at IS NULL OR last_attempt_at <= ?', now - MIN_INTERVAL)
              .update_all(last_attempt_at: now, updated_at: now)
    claimed.positive?
  end

  def self.succeeded!(now: Time.current)
    where(id: current.id).update_all(last_success_at: now, last_error: nil, updated_at: now)
  end

  def self.failed!(reason, now: Time.current)
    where(id: current.id).update_all(last_error: reason.to_s[0, 200], updated_at: now)
  end
end
