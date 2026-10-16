# frozen_string_literal: true

module Core
  # A native source profile. Matching contact details never imply identity;
  # CRM annotations are local and survive subsequent directory refreshes.
  class Customer < ApplicationRecord
    include TenantScoped

    self.table_name = 'customers'

    SOURCES = %w[shopify square ctrax swipesimple pos manual].freeze
    CRM_STATUSES = %w[lead customer vip inactive].freeze

    belongs_to :owner, class_name: 'User', optional: true
    has_many :interactions, class_name: 'CustomerInteraction', dependent: :destroy
    has_many :follow_ups, class_name: 'CustomerFollowUp', dependent: :destroy
    include CustomerWorkspaceAssociations

    before_validation :normalize_tags
    validates :crm_status, inclusion: { in: CRM_STATUSES }
    validates :tags, length: { maximum: 1000 }
    validates :preferred_name, length: { maximum: 255 }
    validates :notes, length: { maximum: 10_000 }

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
        %w[first_name last_name email phone source created_at crm_status tags preferred_name owner_id]
      end

      def ransackable_associations(_auth_object = nil)
        ['orders']
      end
    end

    def name
      preferred_name.presence || [first_name, last_name].compact.join(' ').presence || email || phone || 'Unnamed customer'
    end

    def tag_list
      tags.to_s.split(',').map(&:strip).reject(&:blank?)
    end

    def lifetime_totals
      orders.group(:currency).sum(:gross_cents)
    end

    def lifetime_value_cents
      # Grouped aggregate instead of orders.sum (one SQL SUM per rendered row).
      @lifetime_value_cents ||= orders.pick(Arel.sql('COALESCE(SUM(gross_cents), 0)')).to_i
    end

    private

    def normalize_tags
      self.tags = tag_list.uniq.sort.join(', ')
    end
  end
end
