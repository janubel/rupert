# frozen_string_literal: true

module Webhooks
  # Shared plumbing for Shopify webhook endpoints: HMAC verification (via
  # ShopifyApp::WebhookVerification), fast acknowledgement, and hand-off to a
  # background job. Controllers only name the job; everything else is here so
  # the five endpoints cannot drift apart again (the GDPR endpoints referenced
  # job classes that did not exist until 2026-10-20).
  module ShopifyIngestion
    extend ActiveSupport::Concern

    included do
      skip_before_action :require_login
      skip_before_action :load_last_sync, raise: false
      include ShopifyApp::WebhookVerification
    end

    private

    # Parse the verified request, enqueue the job and answer 204 quickly.
    # Shopify retries on any non-2xx, so a queue outage answers 503 rather
    # than pretending the delivery was processed. A delivery id that was
    # already recorded is acknowledged and skipped (Shopify re-sends on
    # timeouts and after its own retries).
    def ingest(job_class)
      webhook_request = ShopifyAPI::Webhooks::Request.new(raw_body: request.raw_post, headers: request.headers.to_h)
      body = webhook_request.parsed_body
      delivery = WebhookDelivery.record!(provider: 'shopify', delivery_id: request.headers['X-Shopify-Webhook-Id'],
        topic: webhook_request.topic, shop_domain: webhook_request.shop)
      if delivery.nil?
        Rails.logger.info("[webhooks] duplicate Shopify delivery #{request.headers['X-Shopify-Webhook-Id']} for #{webhook_request.topic} ignored")
        return head(:no_content)
      end

      job = job_class.perform_later(shop_domain: webhook_request.shop, webhook: body)
      delivery.update_columns(job_id: job.job_id, status: 'queued')
      head(:no_content)
    rescue JSON::ParserError, ShopifyAPI::Errors::InvalidWebhookError
      head(:bad_request)
    rescue ActiveJob::EnqueueError
      delivery&.update_columns(status: 'failed')
      head(:service_unavailable)
    end
  end
end
