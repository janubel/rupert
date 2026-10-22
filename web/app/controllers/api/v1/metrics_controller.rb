# frozen_string_literal: true

module Api
  module V1
    # Business figures computed by Rupert (Metrics): the same answers the MCP metric tool and team chat use.
    #   GET /api/v1/metrics                 the catalog
    #   GET /api/v1/metrics/:name?period=last_month&compare=previous|last_year|none&source=shopify (or from/to)
    class MetricsController < BaseController
      def index
        return unless require_scope('reports:read')

        render json: { data: ::Metrics.catalog.map { |metric| { name: metric.key, title: metric.title, unit: metric.unit, description: metric.description } },
                       meta: { api_version: 'v1', periods: ::Metrics::PRESETS, compare: ::Metrics::COMPARES } }
      end

      def show
        return unless require_scope('reports:read')

        data = ::Metrics.call(params[:name], period: params[:period], from: params[:from], to: params[:to],
          compare: params[:compare], source: params[:source])
        render json: { data: data, meta: { api_version: 'v1' } }
      rescue ArgumentError => e
        render json: { error: { code: 'invalid_request', message: e.message } }, status: :bad_request
      end
    end
  end
end
