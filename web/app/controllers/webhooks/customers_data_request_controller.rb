# frozen_string_literal: true

module Webhooks
  class CustomersDataRequestController < ApplicationController
    include Webhooks::ShopifyIngestion

    def receive
      ingest(CustomersDataRequestJob)
    end
  end
end
