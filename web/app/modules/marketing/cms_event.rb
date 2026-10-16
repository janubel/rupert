# frozen_string_literal: true

module Marketing
  class CmsEvent < Record
    self.table_name = 'marketing_cms_events'
    encrypts :payload_json
    belongs_to :actor, class_name: 'User'
    validates :subject_type, :subject_id, :action, :payload_json, presence: true
    validates :subject_type, inclusion: { in: %w[Marketing::Influencer Marketing::Engagement Marketing::ProductGift Marketing::Document Marketing::Offer] }
    before_update { raise ActiveRecord::ReadOnlyRecord }
    before_destroy { raise ActiveRecord::ReadOnlyRecord }
  end
end
