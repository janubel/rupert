# frozen_string_literal: true

# One channel message copied from the Buzz relay. A cache, not a record: the relay
# keeps the history, and rows older than the retention window are removed
# (see BuzzChat.purge!). Everything in here came from other people.
class BuzzMessage < ApplicationRecord
  include TenantScoped

  CONTENT_MAX = 4000

  belongs_to :rupert_user, class_name: 'User', optional: true

  scope :in_channel, ->(channel) { where(channel: channel) }
  scope :newest_first, -> { order(posted_at: :desc, event_id: :desc) }
  scope :oldest_first, -> { order(posted_at: :asc, event_id: :asc) }

  # Rows strictly older than a "posted_at:event_id" cursor, as the page pairs them.
  scope :older_than, lambda { |cursor|
    at, id = cursor
    where('posted_at < :at OR (posted_at = :at AND event_id < :id)', at: at, id: id)
  }
  scope :newer_than, lambda { |cursor|
    at, id = cursor
    where('posted_at > :at OR (posted_at = :at AND event_id > :id)', at: at, id: id)
  }

  def cursor = "#{posted_at}:#{event_id}"

  # [posted_at, event_id] from a cursor string, or nil when it is not one.
  def self.parse_cursor(value)
    at, id = value.to_s.split(':', 2)
    return unless at.to_s.match?(/\A\d{1,12}\z/) && id.to_s.match?(/\A[0-9a-f]{64}\z/)

    [at.to_i, id]
  end
end
