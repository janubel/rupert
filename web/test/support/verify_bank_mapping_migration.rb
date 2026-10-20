# frozen_string_literal: true

# Run only against a disposable test DB: bin/rails runner test/support/verify_bank_mapping_migration.rb
raise 'Disposable test environment required' unless Rails.env.test?

require Rails.root.join('db/migrate/20261020150000_create_bank_statement_accounts')
tenant = Tenant.create!(name: 'Migration fixture', subdomain: "mapping-migration-#{SecureRandom.hex(4)}")
Current.tenant = tenant
Finance::ChartOfAccounts.seed!
cash = Finance::Account.find_by!(code: '1000')
bank = Finance::Account.find_by!(code: '1100')
entry = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Synthetic migration test',
  lines: [{ account_id: cash.id, debit_cents: 500 }, { account_id: bank.id, credit_cents: 500 }])
first = BankStatementLine.create!(document_id: 1, line_no: 1, account_label: 'Cash', posted_on: Date.current,
  description: 'Synthetic transfer in', amount_cents: 500, fingerprint: 'migration-in', journal_entry_id: entry.id)
second = BankStatementLine.create!(document_id: 1, line_no: 2, account_label: 'Checking', posted_on: Date.current,
  description: 'Synthetic transfer out', amount_cents: -500, fingerprint: 'migration-out', journal_entry_id: entry.id)
migration = CreateBankStatementAccounts.new
begin
  migration.migrate(:down)
  raise 'Rollback discarded valid cross-account matches'
rescue ActiveRecord::IrreversibleMigration
  raise 'Rollback changed the table before refusing' unless ActiveRecord::Base.connection.table_exists?(:bank_statement_accounts)
end
# Remove only the synthetic second leg to exercise the supported rollback path.
BankStatementLine.where(id: second.id).delete_all
original = first.reload.attributes
migration.migrate(:down)
migration.migrate(:up)
BankStatementLine.reset_column_information
raise 'Migration changed historical statement evidence' unless first.reload.attributes == original
raise 'Migration removed the original journal' unless Finance::JournalEntry.exists?(entry.id)
BankStatementLine.where(tenant_id: tenant.id).delete_all
Finance::JournalLine.where(tenant_id: tenant.id).delete_all
Finance::JournalEntry.where(tenant_id: tenant.id).delete_all
Finance::Account.where(tenant_id: tenant.id).delete_all
tenant.destroy!
puts 'PASS bank mapping migration: down/up preserves evidence; rollback refuses cross-account matches before changing schema'
Current.reset
