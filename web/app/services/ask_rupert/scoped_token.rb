# frozen_string_literal: true

module AskRupert
  # Lets the existing read-only MCP tools run in-process as the signed-in person.
  # It is not a stored token and grants nothing a person does not already have:
  # every read scope is checked against that person's current permissions, no
  # write scope is ever offered, and it exists only for the one request.
  class ScopedToken
    READ_SCOPES = (ApiAccessToken::SCOPES.keys - ApiAccessToken::WRITE_SCOPES).freeze

    attr_reader :user, :tenant

    def initialize(user)
      @user = user
      @tenant = user.tenant
    end

    def id = 'ask-rupert'
    def name = 'Ask Rupert'
    def token_hint = 'ask-rupert'
    def expires_at = nil

    def scopes
      READ_SCOPES.select { |scope| allows?(scope) }
    end

    def usable?
      user.active? && !user.employee? && tenant&.status == 'active' && user.tenant_id == tenant.id
    end

    def allows?(scope)
      return false unless usable? && READ_SCOPES.include?(scope)

      permission = ApiAccessToken::SCOPES[scope]
      permission.nil? || user.can?(permission)
    end
  end
end
