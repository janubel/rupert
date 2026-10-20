# frozen_string_literal: true

module Webhooks
  class AppUninstalledController < ApplicationController
    include Webhooks::ShopifyIngestion

    def receive
      ingest(AppUninstalledJob)
    end
  end
end
