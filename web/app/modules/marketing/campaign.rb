# frozen_string_literal: true

module Marketing
  class Campaign < Record
    self.table_name = 'marketing_campaigns'
    validates :name, :storefront_url, :topics, presence: true
    validates :name, length: { maximum: 200 }
    validates :topics, length: { maximum: 2000 }
    validate { https_fields(:storefront_url) }
  end
end
