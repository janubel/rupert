# frozen_string_literal: true

module Marketing
  class Reply < Record
    self.table_name = 'marketing_replies'
    belongs_to :thread, class_name: 'Marketing::Thread', inverse_of: :reply
    belongs_to :offer
    has_many :review_events, class_name: 'Marketing::ReviewEvent'
    attr_accessor :workflow_write

    validates :body, :affiliation, presence: true
    validates :body, length: { maximum: 5000 }
    validates :affiliation, length: { maximum: 300 }
    validates :thread_id, uniqueness: true
    validates :status, inclusion: { in: %w[draft pending_review approved published rejected removed] }
    validate { same_tenant(:thread, :offer) }
    validate do
      errors.add(:offer, 'must belong to the thread community') unless offer && thread && offer.community_id == thread.community_id
      errors.add(:base, 'Use the reply workflow') unless workflow_write
      https_fields(:published_url) if published_url.present?
      if published_url.present? && Urls.host(published_url) != Urls.host(thread&.url)
        errors.add(:published_url, 'must use the thread platform host')
      end
    end
  end
end
