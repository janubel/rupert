# frozen_string_literal: true

# Ledger catch-up for sales. Both tasks are dry runs: they print what they would
# post and change nothing unless CONFIRM=1 is given with an explicit TENANT_ID.
namespace :finance do
  namespace :sales do
    def finance_tenant!(confirm)
      raise 'CONFIRM=1 writes to tenant data and requires an explicit TENANT_ID' if confirm && ENV['TENANT_ID'].blank?

      tenant = ENV['TENANT_ID'].present? ? Tenant.find_by(id: ENV['TENANT_ID']) : Tenant.where(status: 'active').first
      raise 'No tenant found (set TENANT_ID)' if tenant.nil?

      Current.tenant = tenant
      puts "Tenant: #{tenant.id}"
    end

    def finance_money(cents) = format('$%<amount>.2f', amount: cents.to_i / 100.0)

    desc 'Post completed payments and refunds that have no ledger entry yet (dry run unless CONFIRM=1)'
    task backfill: :environment do
      confirm = ENV['CONFIRM'] == '1'
      finance_tenant!(confirm)
      backfill = Finance::SalesBackfill.new
      rows = backfill.plan
      puts rows.empty? ? 'Nothing to post: every completed payment and refund has a ledger entry.' : 'Month    Kind    Records   Amount'
      rows.each { |row| puts format('%-8s %-7s %7d   %s', row.month, row.kind, row.count, finance_money(row.amount_cents)) }
      if confirm && rows.any?
        result = backfill.apply!
        puts "Posted #{result.posted}. Refused #{result.refused.size}."
        result.refused.tally.each { |reason, count| puts "  #{count}x #{reason}" }
      elsif rows.any?
        puts 'Dry run: nothing was posted. Re-run with CONFIRM=1 and TENANT_ID=<id> to post.'
      end
    end

    desc 'Move card receipts posted to Cash to Card settlements receivable, one entry per month (dry run unless CONFIRM=1)'
    task reclass_card: :environment do
      confirm = ENV['CONFIRM'] == '1'
      finance_tenant!(confirm)
      reclass = Finance::CardReclass.new
      rows = reclass.plan
      puts rows.empty? ? 'Nothing to reclassify.' : 'Month    Payments   Moves from Cash to 1150'
      rows.each { |row| puts format('%-8s %8d   %s', row.month, row.payments, finance_money(row.amount_cents)) }
      puts format('Total    %8d   %s', rows.sum(&:payments), finance_money(rows.sum(&:amount_cents))) if rows.any?
      if confirm && rows.any?
        posted, refused = reclass.apply!
        puts "Posted #{posted.size} monthly entries. Refused #{refused.size}."
        refused.each { |row, reason| puts "  #{row.month}: #{reason}" }
      elsif rows.any?
        puts 'Dry run: nothing was posted. Re-run with CONFIRM=1 and TENANT_ID=<id> to post.'
      end
    end
  end
end
