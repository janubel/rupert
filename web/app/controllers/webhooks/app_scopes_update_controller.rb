# frozen_string_literal: true

module Webhooks
  class AppScopesUpdateController < ApplicationController
    include Webhooks::ShopifyIngestion

    def receive
      ingest(AppScopesUpdateJob)
    end
  end
end
