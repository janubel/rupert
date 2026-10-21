# frozen_string_literal: true

module Finance
  # An expense category this workspace can edit: its name, the ledger account
  # it posts to and keyword hints used to suggest it for bank lines. The key is
  # what expenses store, so renaming never rewrites history. Categories are
  # deactivated, never deleted, so older records keep their label.
  class ExpenseCategory < ApplicationRecord
    include TenantScoped

    self.table_name = 'expense_categories'

    # The original fixed list, seeded the first time a workspace needs it.
    DEFAULT_HINTS = {
      'rent' => %w[rent lease], 'utilities' => %w[electric power water gas internet comcast verizon at&t],
      'insurance' => %w[insurance geico progressive], 'shipping' => %w[usps ups fedex dhl postage stamps.com pirate],
      'software' => %w[shopify square google adobe intuit quickbooks github slack zoom], 'marketing' => %w[mailchimp klaviyo],
      'advertising' => %w[facebook meta ads], 'taxes' => %w[irs tax treasury], 'labor' => %w[payroll gusto adp],
      'supplies' => %w[amazon staples uline walmart target home depot lowes]
    }.freeze

    belongs_to :ledger_account, class_name: 'Finance::Account', optional: true

    validates :key, presence: true, uniqueness: { scope: :tenant_id }, format: { with: /\A[a-z][a-z0-9_]{0,39}\z/ }
    validates :name, presence: true, length: { maximum: 60 }, uniqueness: { scope: :tenant_id, case_sensitive: false }
    validates :keywords, length: { maximum: 2000 }
    validate :ledger_account_is_expense

    before_validation :derive_key, on: :create
    before_update :keep_key

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:position, :name) }

    class << self
      # Make sure the built-in categories exist for this workspace. Idempotent.
      def ensure_defaults!
        return if where(built_in: true).count >= Finance::Expense::CATEGORIES.size

        accounts = Finance::Account.where(code: Finance::Posting::EXPENSE_BY_CATEGORY.values).index_by(&:code)
        rows = Finance::Expense::CATEGORIES.each_with_index.map do |key, index|
          { tenant_id: Current.tenant_id, key: key, name: key.tr('_', ' ').titleize, built_in: true, active: true, position: index * 10,
            ledger_account_id: accounts[Finance::Posting::EXPENSE_BY_CATEGORY[key]]&.id, keywords: DEFAULT_HINTS.fetch(key, []).join(', ') }
        end
        # Skips keys that already exist, so concurrent first visits are safe.
        insert_all(rows, unique_by: %i[tenant_id key])
      end

      def catalog
        ensure_defaults!
        ordered.to_a
      end

      # [label, key] pairs for selects. Keeps a record's current (possibly
      # inactive) category selectable so editing it doesn't silently change it.
      def options(include_key: nil)
        catalog.select { |c| c.active || c.key == include_key }.map { |c| [c.active ? c.name : "#{c.name} (inactive)", c.key] }
      end

      def active_keys = catalog.select(&:active).map(&:key)
      def known_keys = catalog.map(&:key)
      def label_for(key) = catalog.find { |c| c.key == key }&.name || key.to_s.tr('_', ' ').titleize
      def find_key(key) = catalog.find { |c| c.key == key }

      # First active category whose keyword appears in the text, else nil.
      def suggest(text, categories = nil)
        haystack = text.to_s.downcase
        (categories || catalog).select(&:active).find { |c| c.keyword_list.any? { |word| haystack.include?(word) } }&.key
      end
    end

    def keyword_list
      keywords.to_s.split(/[,\n]/).map { |word| word.strip.downcase }.reject { |word| word.length < 2 }.uniq
    end

    def in_use_count = Finance::Expense.unscoped.where(tenant_id: tenant_id, category: key).count

    private

    def derive_key
      return if key.present?

      base = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')[0, 30].presence || 'category'
      base = "c_#{base}" unless base.match?(/\A[a-z]/)
      candidate = base
      suffix = 1
      candidate = "#{base}_#{suffix += 1}" while self.class.exists?(key: candidate)
      self.key = candidate
    end

    def keep_key
      self.key = key_was if key_changed?
    end

    def ledger_account_is_expense
      return if ledger_account.nil? || (ledger_account.account_type == 'expense' && ledger_account.tenant_id == tenant_id)

      errors.add(:ledger_account, 'must be an expense account in this workspace')
    end
  end
end
