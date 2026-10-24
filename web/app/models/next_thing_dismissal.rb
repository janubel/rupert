# frozen_string_literal: true

# One person's "Done" or "Snooze" on a Next thing to do item. Done hides the item until it changes (its
# fingerprint), and a problem marked done comes back after FIX_DONE_FOR even if unchanged. Snooze hides it
# for SNOOZE_FOR whatever happens.
class NextThingDismissal < ApplicationRecord
  include TenantScoped

  KINDS = %w[done snooze].freeze
  SNOOZE_FOR = 1.hour
  FIX_DONE_FOR = 12.hours

  belongs_to :user
  validates :item_key, presence: true, length: { maximum: 200 }
  validates :kind, inclusion: { in: KINDS }

  def hides?(item, now = Time.current)
    return false if until_at && until_at <= now

    kind == 'snooze' || fingerprint == item[:fingerprint]
  end
end
