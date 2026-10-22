# frozen_string_literal: true

module TeamChat
  # A channel everyone allowed to use team chat can open, or a direct room
  # between one person and Rupert that only that person can open.
  class Room < ApplicationRecord
    include TenantScoped

    KINDS = %w[channel direct].freeze
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

    # Channels plus this person's own direct room.
    scope :visible_to, lambda { |user|
      open.where(kind: 'channel').or(open.where(kind: 'direct', created_by_id: user.id))
    }

    def self.ensure_defaults!(user)
      general = channels.find_by(slug: 'general') ||
                create!(name: 'general', slug: 'general', topic: 'Anything for the team. Mention @rupert to ask about the business.', created_by: user)
      direct_for(user)
      general
    end

    # The person's private room with Rupert, where he answers every message.
    def self.direct_for(user)
      find_by(kind: 'direct', created_by_id: user.id) ||
        create!(kind: 'direct', name: 'Rupert', slug: "rupert-#{user.id}", assistant_mode: 'all', created_by: user,
          topic: 'Just you and Rupert. Ask about sales, stock, staff, tasks or how Rupert works.')
    end

    def direct? = kind == 'direct'
    def channel? = kind == 'channel'
    def archived? = archived_at.present?

    def visible_to?(user)
      return false if archived?

      channel? || created_by_id == user.id
    end

    def membership_for(user)
      memberships.find_or_create_by!(user_id: user.id)
    rescue ActiveRecord::RecordNotUnique
      memberships.find_by!(user_id: user.id)
    end

    def display_name = direct? ? 'Rupert' : name

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
