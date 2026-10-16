# frozen_string_literal: true

module Directories
  class ShopifyStaff
    ACCESS_QUERY = 'query AccessScopeList { currentAppInstallation { accessScopes { handle } } }'
    QUERY = <<~GRAPHQL
      query RupertStaff($cursor: String) {
        staffMembers(first: 100, after: $cursor, sortKey: ID) {
          pageInfo { hasNextPage endCursor }
          nodes { id firstName lastName email active }
        }
      }
    GRAPHQL

    def self.fetch
      scopes = ShopifyClient.graphql(ACCESS_QUERY).fetch('currentAppInstallation').fetch('accessScopes')
      raise Sync::Error unless scopes.is_a?(Array) && scopes.any? { |scope| scope['handle'] == 'read_users' }

      ShopifyCustomers.fetch_directory(QUERY, 'staffMembers', 'StaffMember')
    rescue KeyError, TypeError, NoMethodError, ShopifyClient::Error
      raise Sync::Error
    end
  end
end
