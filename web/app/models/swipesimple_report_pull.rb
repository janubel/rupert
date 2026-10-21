# frozen_string_literal: true

# The date range one SwipeSimple report CSV covered, with its raw bytes. Days
# inside a pulled range that have no stored row had no sales in SwipeSimple;
# days outside every pulled range are unknown.
class SwipesimpleReportPull < ApplicationRecord
  include TenantScoped

  TOPICS = %w[tax sales].freeze
  encrypts :original_csv
  validates :tenant_id, :merchant_account, :period_from, :period_to, :source_digest, :pulled_at, presence: true
  validates :topic, inclusion: { in: TOPICS }

  # { merchant account => Set of dates in from..to covered by a pull }.
  def self.coverage(topic, from, to)
    where(topic: topic).where('period_from <= ? AND period_to >= ?', to, from).pluck(:merchant_account, :period_from, :period_to)
      .each_with_object({}) do |(account, first, last), covered|
        (covered[account] ||= Set.new).merge([first, from].max..[last, to].min)
      end
  end
end
