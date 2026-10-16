# frozen_string_literal: true

module Marketing
  class ReviewEvent < Record
    self.table_name = 'marketing_review_events'
    belongs_to :reply
    validates :actor_id, :action, :payload_json, presence: true
    validate { same_tenant(:reply) }
    before_update { raise ActiveRecord::ReadOnlyRecord }
    before_destroy { raise ActiveRecord::ReadOnlyRecord }
  end
end
