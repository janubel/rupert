# frozen_string_literal: true

module TeamChat
  # A channel everyone allowed to use team chat can open; a direct room between
  # one person and Rupert that only that person can open; or a direct message
  # (dm) between two people that only those two can open.
  class Room < ApplicationRecord
    include TenantScoped

    KINDS = %w[channel direct dm].freeze
    ASSISTANT_MODES = { 'mentions' => 'When mentioned (@rupert)', 'all' => 'To every message', 'off' => 'Off' }.freeze
    NAME_MAX = 60
    TOPIC_MAX = 240

    has_many :memberships, class_name: 'TeamChat::Membership', dependent: :destroy
    has_many :members, through: :memberships, source: :user
    has_many :messages, class_name: 'TeamChat::Message', dependent: :destroy
    belongs_to :created_by, class_name: 'User', optional: true

    validates :name, presence: true, length: { maximum: NAME_MAX }
    validates :topic, length: { maximum: TOPIC_MAX }
    validates :kind, inclusion: { in: KINDS }
    validates :assistant_mode, inclusion: { in: ASSISTANT_MODES.keys }
    validates :slug, presence: true, uniqueness: { scope: :tenant_id }, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }

    before_validation :assign_slug, on: :create

    scope :open, -> { where(archived_at: nil) }
    scope :channels, -> { where(kind: 'channel') }

    # Channels, this person's own room with Rupert and their direct messages.
    scope :visible_to, lambda { |user|
      open.where(kind: 'channel').or(open.where(kind: 'direct', created_by_id: user.id))
          .or(open.where(kind: 'dm', id: Membership.where(user_id: user.id).select(:room_id)))
    }

    MAIN_SLUG = 'admins'
    MAIN_TOPIC = 'All admins, with Rupert. Mention @rupert — or a model like @deepseek or @qwen — to ask about the business.'

    # #admins holds every person who can use team chat, plus Rupert. (It was #general;
    # an existing #general is renamed in place, so its history and links carry over.)
    def self.ensure_defaults!(user)
      general = channels.find_by(slug: MAIN_SLUG) ||
                channels.find_by(slug: 'general')&.tap { |room| room.update!(name: MAIN_SLUG, slug: MAIN_SLUG, topic: MAIN_TOPIC) } ||
                create!(name: MAIN_SLUG, slug: MAIN_SLUG, topic: MAIN_TOPIC, created_by: user)
      everyone = Post.mentionable
      general.add_members(everyone) if general.memberships.count < everyone.size
      general.membership_for(user)
      direct_for(user)
      general
    end

    # The direct-message room between two people (created on first use).
    def self.dm_between(user, other)
      raise ArgumentError, 'pick someone else' if user.id == other.id

      low, high = [user.id, other.id].minmax
      room = find_by(kind: 'dm', slug: "dm-#{low}-#{high}") ||
             create!(kind: 'dm', slug: "dm-#{low}-#{high}", name: 'Direct message', assistant_mode: 'mentions', created_by: user)
      room.add_members([user, other])
      room
    rescue ActiveRecord::RecordNotUnique
      find_by!(kind: 'dm', slug: "dm-#{low}-#{high}")
    end

    # The person's private room with Rupert, where he answers every message.
    def self.direct_for(user)
      find_by(kind: 'direct', created_by_id: user.id) ||
        create!(kind: 'direct', name: 'Rupert', slug: "rupert-#{user.id}", assistant_mode: 'all', created_by: user,
          topic: 'Just you and Rupert. Ask about sales, stock, staff, tasks or how Rupert works.')
    end

    def direct? = kind == 'direct'
    def dm? = kind == 'dm'
    def channel? = kind == 'channel'
    def archived? = archived_at.present?

    def visible_to?(user)
      return false if archived?

      return memberships.exists?(user_id: user.id) if dm?

      channel? || created_by_id == user.id
    end

    def add_members(users)
      users.each { |person| membership_for(person) }
    end

    # The other person in a direct message.
    def dm_partner(viewer)
      return nil unless dm?

      members.where.not(id: viewer.id).first
    end

    def membership_for(user)
      memberships.find_or_create_by!(user_id: user.id)
    rescue ActiveRecord::RecordNotUnique
      memberships.find_by!(user_id: user.id)
    end

    def display_name(viewer = nil)
      return 'Rupert' if direct?
      return dm_partner(viewer)&.display_name || 'Direct message' if dm? && viewer

      name
    end

    def to_param = slug

    private

    def assign_slug
      return if slug.present?

      base = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '').first(40).presence || 'room'
      candidate = base
      index = 1
      while Room.exists?(slug: candidate)
        index += 1
        candidate = "#{base}-#{index}"
      end
      self.slug = candidate
    end
  end
end
