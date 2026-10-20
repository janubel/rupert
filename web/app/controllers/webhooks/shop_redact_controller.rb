# frozen_string_literal: true

module Webhooks
  class ShopRedactController < ApplicationController
    include Webhooks::ShopifyIngestion

    def receive
      ingest(ShopRedactJob)
    end
  end
end
