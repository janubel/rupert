# frozen_string_literal: true

# A Buzz identity's public name (the kind 0 profile event), cached so the chat can
# show a person instead of a key. The name is chosen by that person and is
# untrusted text: it is cleaned and capped on the way in and escaped on display.
class BuzzProfile < ApplicationRecord
  include TenantScoped

  REFRESH_AFTER = 6.hours

  scope :fresh, -> { where(fetched_at: REFRESH_AFTER.ago..) }

  def label
    display_name.presence || name.presence
  end
end
