# frozen_string_literal: true

module Api
  module V1
    # Independent bearer authentication: browser sessions and host subdomains
    # never select an API tenant, and no API action can mutate platform data.
    class BaseController < ActionController::API
      around_action :isolated_context
      before_action :authenticate_token

      rescue_from ActiveRecord::RecordNotFound, with: :not_found

      private

      def isolated_context
        Current.reset
        response.headers['Cache-Control'] = 'no-store'
        yield
      ensure
        Current.reset
      end

      def authenticate_token
        header = request.headers['Authorization'].to_s
        secret = header.match(/\ABearer (\S+)\z/i)&.captures&.first
        @api_token = ApiAccessToken.authenticate(secret)
        unless @api_token
          response.headers['WWW-Authenticate'] = 'Bearer realm="Rupert API"'
          render json: { error: { code: 'unauthorized', message: 'A valid bearer token is required.' } }, status: :unauthorized
          return
        end
        Current.user = @api_token.user
        Current.tenant = @api_token.tenant
      end

      def require_scope(scope)
        return true if @api_token.allows?(scope)

        render json: { error: { code: 'forbidden', message: "This token cannot access #{scope}." } }, status: :forbidden
        false
      end

      def pagination
        page = params.fetch(:page, '1').to_s
        per_page = params.fetch(:per_page, '50').to_s
        unless page.match?(/\A\d+\z/) && (1..1000).cover?(page.to_i) &&
            per_page.match?(/\A\d+\z/) && (1..100).cover?(per_page.to_i)
          render json: { error: { code: 'invalid_pagination', message: 'page must be 1–1000 and per_page must be 1–100.' } }, status: :bad_request
          return
        end
        [page.to_i, per_page.to_i]
      end

      def render_page(scope, meta: {})
        bounds = pagination
        return unless bounds

        page, per_page = bounds
        rows = scope.offset((page - 1) * per_page).limit(per_page + 1).to_a
        more = rows.length > per_page
        render json: {
          data: rows.first(per_page).map { |row| yield(row) },
          meta: { api_version: 'v1', page: page, per_page: per_page, has_more: more,
            next_page: more && page < 1000 ? page + 1 : nil }.merge(meta)
        }
      end

      def not_found
        render json: { error: { code: 'not_found', message: 'Resource not found.' } }, status: :not_found
      end
    end
  end
end
