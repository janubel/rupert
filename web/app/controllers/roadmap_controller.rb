# frozen_string_literal: true

# Product information only; viewing a roadmap never enables a platform write.
class RoadmapController < AuthenticatedController
  def index
    @catalog = JSON.parse(Rails.root.join('config/product_roadmap.json').read)
  end
end
