# frozen_string_literal: true

module Finance
  # A chart of accounts entry: the classification skeleton that every general
  # ledger transaction posts against. Basic today (accounts only, no journal
  # entries yet) but the accounts are the foundation of the ledger.
  class Account < ApplicationRecord
    include TenantScoped

    self.table_name = 'accounts'

    TYPES = %w[asset liability equity revenue expense].freeze
    TYPE_LABELS = {
      'asset' => 'Assets',
      'liability' => 'Liabilities',
      'equity' => 'Equity',
      'revenue' => 'Revenue',
      'expense' => 'Expenses'
    }.freeze
    # The side that increases the account's balance, by type.
    NORMAL_BALANCE = {
      'asset' => 'debit',
      'liability' => 'credit',
      'equity' => 'credit',
      'revenue' => 'credit',
      'expense' => 'debit'
    }.freeze

    validates :code, presence: true
    validates :name, presence: true
    validates :account_type, inclusion: { in: TYPES }
    validates :normal_balance, inclusion: { in: NORMAL_BALANCE.values }
    validates :code, uniqueness: { scope: :tenant_id, case_sensitive: false }
    validate :classification_fixed_once_used, on: :update

    scope :by_type, ->(type) { type.present? && type != 'all' ? where(account_type: type) : all }
    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:code) }

    # When the balance side isn't chosen, derive it from the account type.
    before_validation :set_normal_balance, if: -> { normal_balance.blank? }

    def type_label
      TYPE_LABELS.fetch(account_type, account_type.titleize)
    end

    def label
      [code, name].compact.join(' · ')
    end

    def used_in_ledger?
      persisted? && Finance::JournalLine.where(account_id: id).exists?
    end

    private

    # Code, type and balance side drive every report and export. Once an account
    # carries ledger lines, changing them would silently restate posted history
    # (and a wrong balance side breaks the balance sheet), so they are fixed;
    # open a new account instead. Name, description and archiving stay editable.
    def classification_fixed_once_used
      fixed = changed & %w[code account_type normal_balance]
      return if fixed.empty? || !used_in_ledger?

      errors.add(:base, "#{fixed.map(&:humanize).to_sentence} cannot change on an account that already has ledger entries. Create a new account instead.")
    end

    def set_normal_balance
      self.normal_balance = NORMAL_BALANCE[account_type]
    end
  end
end
