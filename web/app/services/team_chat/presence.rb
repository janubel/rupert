# frozen_string_literal: true

module TeamChat
  # "Recently active" dots in team chat. Rupert notes when each person last
  # used it (page views, and the chat while its tab is in front). Each person
  # can hide their own status, unless the workspace rule decides for them:
  # for everyone, or per role (Rupert's groups).
  module Presence
    ACTIVE_FOR = 5.minutes
    RECENT_FOR = 1.hour
    TOUCH_EVERY = 1.minute
    SETTING = 'team_chat_presence'
    MODES = { 'choice' => 'Each person chooses', 'on' => 'Always shown', 'off' => 'Never shown' }.freeze

    module_function

    # Records activity at most once a minute (one small UPDATE).
    def touch(user)
      return unless user&.active? && user.has_attribute?(:last_active_at)
      return if user.last_active_at && user.last_active_at > TOUCH_EVERY.ago

      user.update_column(:last_active_at, Time.current)
    end

    # { 'everyone' => 'choice', 'roles' => { 'manager' => 'on' } } for the current workspace.
    def policy
      raw = Setting.find_by(key: SETTING, tenant_id: Current.tenant_id)&.value
      data = raw.present? ? JSON.parse(raw) : {}
      everyone = MODES.key?(data['everyone']) ? data['everyone'] : 'choice'
      roles = data['roles'].is_a?(Hash) ? data['roles'].select { |role, mode| User.roles.key?(role) && MODES.key?(mode) } : {}
      { 'everyone' => everyone, 'roles' => roles }
    rescue JSON::ParserError
      { 'everyone' => 'choice', 'roles' => {} }
    end

    def save_policy!(everyone:, roles:)
      clean = { 'everyone' => MODES.key?(everyone.to_s) ? everyone.to_s : 'choice',
                'roles' => roles.to_h.to_h { |role, mode| [role.to_s, mode.to_s] }
                                .select { |role, mode| User.roles.key?(role) && MODES.key?(mode) && mode != 'same' } }
      Setting.find_or_create_for(SETTING, Current.tenant_id) { |setting| setting.value = JSON.generate(clean) }
      clean
    end

    # The rule that applies to this person: 'choice', 'on' or 'off'.
    def mode_for(user, rules = policy)
      rules['roles'][user.role.to_s] || rules['everyone']
    end

    # Whether this person's activity may be shown, and why not when it may not.
    def shown?(user, rules = policy)
      case mode_for(user, rules)
      when 'on' then true
      when 'off' then false
      else !user.presence_hidden
      end
    end

    # Admins set the workspace rule.
    def manage?(user) = user&.active? && (user.admin? || user.super_admin?)

    # { state: 'active' | 'recent', label: 'Active now' | 'Active 23 min ago' } or nil.
    def status(user, rules = policy, now: Time.current)
      return nil unless user.last_active_at && shown?(user, rules)

      ago = now - user.last_active_at
      return { state: 'active', label: 'Active now' } if ago <= ACTIVE_FOR
      return { state: 'recent', label: "Active #{(ago / 60).round} min ago" } if ago <= RECENT_FOR

      nil
    end

    # { user_id => status } for these people (only those with something to show).
    def statuses(users)
      rules = policy
      now = Time.current
      users.each_with_object({}) do |user, map|
        found = status(user, rules, now: now)
        map[user.id] = found if found
      end
    end
  end
end
