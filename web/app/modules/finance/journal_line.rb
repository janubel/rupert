# frozen_string_literal: true

module Finance
  # A single debit or credit leg of a journal entry, posting to one account.
  # Exactly one side carries the amount; a line is never both a debit and a
  # credit, and never zero.
  class JournalLine < ApplicationRecord
    include TenantScoped

    self.table_name = 'journal_lines'

    belongs_to :journal_entry
    belongs_to :account, class_name: 'Finance::Account'

    validates :account, presence: true
    validates :debit_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
    validates :credit_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
    validate :one_sided_amount

    # Posted legs are permanent: corrections are made by voiding the entry and
    # posting a new one, never by editing or deleting a leg in place (audit
    # #169 M3). The database adds foreign keys and a one-sided CHECK.
    def readonly? = persisted? || super

    def amount_cents = [debit_cents.to_i, credit_cents.to_i].max
    def debit? = debit_cents.to_i.positive?
    def credit? = credit_cents.to_i.positive?
    def side = debit? ? 'debit' : 'credit'

    private

    def one_sided_amount
      debit = debit_cents.to_i
      credit = credit_cents.to_i
      if debit.positive? && credit.positive?
        errors.add(:base, 'A line is either a debit or a credit, not both.')
      elsif debit.zero? && credit.zero?
        errors.add(:base, 'A line must carry a debit or a credit amount.')
      end
    end
  end
end
