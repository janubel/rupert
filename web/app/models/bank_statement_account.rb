# frozen_string_literal: true

# Explicit statement-label to ledger-account mapping. No historical label is guessed.
class BankStatementAccount < ApplicationRecord
  include TenantScoped

  belongs_to :ledger_account, class_name: 'Finance::Account'
  validates :account_label, presence: true, uniqueness: { scope: :tenant_id }
  validates :ledger_account_id, uniqueness: { scope: :tenant_id }
  validate :eligible_account
  validate :preserve_existing_links

  def self.available_accounts
    Finance::Account.active.where(account_type: 'asset', normal_balance: 'debit').ordered
  end

  private

  def eligible_account
    return if ledger_account && ledger_account.tenant_id == tenant_id &&
      ledger_account.active? && ledger_account.account_type == 'asset' && ledger_account.normal_balance == 'debit'

    errors.add(:ledger_account, 'must be an active asset account in this workspace')
  end

  def preserve_existing_links
    return unless ledger_account
    links = BankStatementLine.where(account_label: account_label).where.not(journal_entry_id: nil)
    if persisted? && (will_save_change_to_ledger_account_id? || will_save_change_to_account_label?) &&
        BankStatementLine.where(account_label: account_label_in_database).where.not(journal_entry_id: nil).exists?
      errors.add(:base, 'This mapping has linked statement lines. Review their source records and clear manual matches before changing it.')
      return
    end
    links.includes(journal_entry: { journal_lines: :account }).find_each do |line|
      entry = line.journal_entry
      signed = entry&.journal_lines&.select { |leg| leg.account_id == ledger_account_id }&.sum { |leg| leg.debit_cents - leg.credit_cents }
      next if entry&.status == 'posted' && entry.tenant_id == tenant_id && signed == line.amount_cents

      errors.add(:base, 'Existing journal links do not agree with this ledger account. Review them before mapping; no history was changed.')
      break
    end
  end
end
