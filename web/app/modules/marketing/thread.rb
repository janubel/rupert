# frozen_string_literal: true

module Marketing
  class Thread < Record
    self.table_name = 'marketing_threads'
    belongs_to :community
    has_one :reply, class_name: 'Marketing::Reply', inverse_of: :thread
    before_validation { self.url = Urls.canonical(url) }
    before_update do
      self.checked_at = nil if %w[url title excerpt community_id availability].any? { |field| will_save_change_to_attribute?(field) }
    end
    validates :url, uniqueness: { scope: :tenant_id }
    validates :title, :excerpt, presence: true
    validates :title, length: { maximum: 300 }
    validates :excerpt, :triage_note, length: { maximum: 5000 }
    validates :status, inclusion: { in: %w[new relevant dismissed snoozed] }
    validates :availability, inclusion: { in: %w[open locked deleted] }
    validate { same_tenant(:community) }
    validate { https_fields(:url) }
    validate do
      errors.add(:url, 'must use the community host') unless Urls.host(url) == Urls.host(community&.url)
      errors.add(:triage_note, 'is required when dismissing or snoozing') if %w[dismissed snoozed].include?(status) && triage_note.blank?
      errors.add(:snoozed_until, 'must be in the future') if status == 'snoozed' && (!snoozed_until || snoozed_until <= Time.current)
    end

    def relevance
      text = "#{title}\n#{excerpt}".downcase
      { matched: community.terms(:include_terms).select { |term| text.include?(term.downcase) },
        excluded: community.terms(:exclude_terms).select { |term| text.include?(term.downcase) } }
    end

    def eligible?
      status == 'relevant' && availability == 'open' && checked_at && checked_at <= Time.current &&
        checked_at > 7.days.ago && community.rules_current?
    end
  end
end
