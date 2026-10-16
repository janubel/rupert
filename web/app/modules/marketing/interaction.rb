# frozen_string_literal: true

module Marketing
  class Interaction < Record
    self.table_name = 'marketing_interactions'
    belongs_to :influencer
    belongs_to :actor, class_name: 'User'
    encrypts :body
    validates :kind, inclusion: { in: %w[email dm call meeting note] }
    validates :body, presence: true, length: { maximum: 5000 }
    validates :occurred_at, presence: true
    validate { same_tenant(:influencer) }
    validate { errors.add(:occurred_at, 'cannot be in the future') if occurred_at && occurred_at > 1.minute.from_now }
    before_update { raise ActiveRecord::ReadOnlyRecord }
    before_destroy { raise ActiveRecord::ReadOnlyRecord }
  end
end
