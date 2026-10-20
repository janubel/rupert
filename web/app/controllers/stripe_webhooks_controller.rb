# frozen_string_literal: true

class StripeWebhooksController < ActionController::Base
  skip_forgery_protection
  def create
    payload = request.raw_post
    return head :payload_too_large if payload.bytesize > 1_048_576
    RupertBilling.verify_signature!(payload, request.headers['Stripe-Signature'])
    RupertBilling.receive(JSON.parse(payload))
    head :ok
  rescue RupertBilling::Error, JSON::ParserError, KeyError
    # A non-2xx delivery is retried; never acknowledge a failed synchronization.
    head :bad_request
  end
end
