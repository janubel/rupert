# frozen_string_literal: true

# An in-app message for one person: a task assigned to them, a comment on their
# work, something due. Delivery is best effort and never raises, so a failure
# here cannot break the action that caused it. People never notify themselves.
class Notification < ApplicationRecord
  include TenantScoped

  belongs_to :user

  validates :kind, :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :newest, -> { order(created_at: :desc, id: :desc) }

  # dedupe_key makes a reminder idempotent per person: a second delivery with
  # the same key is dropped. actor: nil (reminders) notifies whoever is named.
  def self.deliver(user_id, kind:, title:, body: nil, url: nil, dedupe_key: nil, actor: Current.user)
    return if user_id.blank? || actor&.id.to_s == user_id.to_s
    return unless User.where(tenant_id: Current.tenant_id).active.exists?(id: user_id)

    create(user_id: user_id, kind: kind, title: title.to_s.first(200), body: body.to_s.first(500).presence,
      url: url, dedupe_key: dedupe_key)
  rescue ActiveRecord::ActiveRecordError
    nil
  end

  def self.unread_count_for(user)
    where(user_id: user.id).unread.count
  end

  def read? = read_at.present?
end
