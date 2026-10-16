# frozen_string_literal: true

module Marketing
  class Community < Record
    self.table_name = 'marketing_communities'
    belongs_to :campaign
    validates :name, :url, :include_terms, :promotion_rules, :rules_url, presence: true
    validates :name, length: { maximum: 200 }
    validates :include_terms, :exclude_terms, length: { maximum: 2000 }
    validates :promotion_rules, length: { maximum: 5000 }
    validate { same_tenant(:campaign) }
    validate { https_fields(:url, :rules_url) }
    before_update :invalidate_rules

    def terms(field)
      public_send(field).to_s.split(/[,\n]/).map(&:strip).reject(&:empty?).first(30)
    end

    def search_url
      uri = URI.parse(url)
      query = ["site:#{uri.host}#{uri.path}", *terms(:include_terms).first(6), *terms(:exclude_terms).first(6).map { |term| "-\"#{term}\"" }].join(' ')
      "https://www.bing.com/search?#{URI.encode_www_form(q: query)}"
    end

    def rules_current?
      rules_checked_at && rules_checked_at <= Time.current && rules_checked_at > 30.days.ago
    end

    private

    def invalidate_rules
      self.rules_checked_at = nil if %w[url promotion_rules rules_url].any? { |field| will_save_change_to_attribute?(field) }
    end
  end
end
