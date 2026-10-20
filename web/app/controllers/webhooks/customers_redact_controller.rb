# frozen_string_literal: true

module Webhooks
  class CustomersRedactController < ApplicationController
    include Webhooks::ShopifyIngestion

    def receive
      ingest(CustomersRedactJob)
    end
  end
end
