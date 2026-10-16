# frozen_string_literal: true

module Core
  # Canonical customer record. Every sales channel (Shopify, Square POS,
  # manual walk-ins) upserts here keyed by (source, external_id) so CRM and
  # reports have one unified view of a person.
  class Customer < ApplicationRecord
    include TenantScoped

    self.table_name = 'customers'

    SOURCES = %w[shopify square ctrax pos manual].freeze

    has_many :orders, class_name: 'Core::Order', foreign_key: :customer_id

    def self.policy_class
      CustomerPolicy
    end

    validates :external_id, presence: true
    validates :source, inclusion: { in: SOURCES }

    scope :search, lambda { |term|
      if term.present?
        where(SearchSql.contains_any(%w[first_name last_name email phone]), *Array.new(4, "%#{term}%"))
      end
    }

    class << self
      def ransackable_attributes(_auth_object = nil)
        %w[first_name last_name email phone source created_at]
      end

      def ransackable_associations(_auth_object = nil)
        ['orders']
      end
    end

    def name
      [first_name, last_name].compact.join(' ').presence || email || phone || 'Unnamed customer'
    end

    def lifetime_value_cents
      # Grouped aggregate instead of orders.sum (one SQL SUM per rendered row).
      @lifetime_value_cents ||= orders.pick(Arel.sql('COALESCE(SUM(gross_cents), 0)')).to_i
    end
  end
end
