# frozen_string_literal: true

module TeamChat
  # Lets Rupert's MCP tools run in-process as one person, the same way Ask
  # Rupert does. Read scopes follow that person's permissions. A write scope is
  # only allowed when `write:` names it, which happens when a person presses
  # Approve on a proposed action, never while the model is running.
  class Token
    attr_reader :user, :tenant

    def initialize(user, write: nil)
      @user = user
      @tenant = user.tenant
      @write = write
    end

    def id = 'team-chat'
    def name = 'Team chat'
    def token_hint = 'team-chat'
    def expires_at = nil

    def scopes = ApiAccessToken::SCOPES.keys.select { |scope| allows?(scope) }

    def usable?
      user.active? && !user.employee? && tenant&.status == 'active' && user.tenant_id == tenant.id
    end

    def allows?(scope)
      return false unless usable? && ApiAccessToken::SCOPES.key?(scope)
      return false if ApiAccessToken::WRITE_SCOPES.include?(scope) && scope != @write

      permission = ApiAccessToken::SCOPES[scope]
      permission.nil? || user.can?(permission)
    end
  end
end
