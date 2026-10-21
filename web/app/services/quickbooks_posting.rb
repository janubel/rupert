# frozen_string_literal: true

# The only code that turns a reviewed QuickBooks batch into business records,
# and the only code that takes them back out. Every path is explicit:
#
# * approving a journal batch posts each staged transaction as a balanced
#   journal entry (kind "imported", linked back to its ImportTransaction), but
#   only transactions on or before the date the person chose, in unlocked
#   periods, whose accounts they mapped. Everything else stays staged with the
#   reason written on it.
# * reversing a batch voids the entries it posted. It is all or nothing and is
#   refused while any of them sits in a locked period.
# * nothing here edits an existing entry, unlocks a period or guesses a mapping.
class QuickbooksPosting
  Error = Class.new(ArgumentError)

  Result = Struct.new(:posted, :held, keyword_init: true)
  ENTITY_TYPES = { 'journal' => 'account', 'chart_of_accounts' => 'account', 'trial_balance' => 'account', 'vendors' => 'vendor', 'customers' => 'customer' }.freeze

  class << self
    # Accounts used by the batch's staged transactions, with the person's decision.
    def account_usage(batch)
      lines = batch.lines.where(status: %w[staged posted])
      rows = lines.group(:account_name).pluck(:account_name, Arel.sql('COUNT(*)'), Arel.sql('SUM(debit_cents)'), Arel.sql('SUM(credit_cents)'))
      mappings = ImportEntityMapping.where(entity_type: ENTITY_TYPES.fetch(batch.kind), source_key: rows.map { |name, *| ImportEntityMapping.key_for(name) }).index_by(&:source_key)
      rows.sort_by { |name, *| name.to_s }.map do |name, count, debit, credit|
        { name: name, lines: count, debit_cents: debit.to_i, credit_cents: credit.to_i, mapping: mappings[ImportEntityMapping.key_for(name)] }
      end
    end

    def undecided_accounts(batch)
      account_usage(batch).select { |row| row[:mapping].nil? || !row[:mapping].decided? }
    end

    # Day before Rupert's own first posted entry: past that date QuickBooks and
    # Rupert would both be recording the same business.
    def suggested_cutover
      first = Finance::JournalEntry.posted.where.not(kind: 'imported').minimum(:posted_on)
      first && first - 1
    end

    def native_entries_between(from, to)
      return 0 unless from && to

      Finance::JournalEntry.posted.where.not(kind: 'imported').where(posted_on: from..to).count
    end

    def approved_ranges
      BookApproval.chronological.to_a.group_by { |a| [a.period_kind, a.period_from] }.values.map(&:last).select(&:approved?)
        .map { |a| [a.period_from, a.period_to] }
    end

    def approve!(batch, actor:, post_through: nil, allow_resembling: false, allow_approved_periods: false)
      raise Error, 'This batch has already been closed.' unless %w[staged approved].include?(batch.status)

      case batch.kind
      when 'journal' then approve_journal!(batch, actor, post_through, allow_resembling, allow_approved_periods)
      when 'chart_of_accounts', 'vendors', 'customers', 'trial_balance' then approve_list!(batch, actor)
      end
    end

    def reverse!(batch, actor:, reason:)
      reason = reason.to_s.strip
      raise Error, 'Write the reason for reversing this import (up to 2,000 characters).' unless reason.length.between?(1, 2000)
      raise Error, 'Only an approved batch can be reversed. Discard a batch that was never approved.' unless batch.approved?

      ImportBatch.transaction do
        lock_workspace!
        txns = batch.transactions.where(status: 'posted').to_a
        entries = Finance::JournalEntry.where(id: txns.filter_map(&:journal_entry_id)).to_a
        locked = entries.filter_map { |entry| PeriodLock.lock_covering(entry.posted_on) }.uniq(&:id)
        if locked.any?
          raise Error, "Nothing was reversed: #{locked.first(3).map(&:label).to_sentence} #{locked.size == 1 ? 'is' : 'are'} locked. " \
                       'Unlock the period on the Books desk, with a reason, then reverse again.'
        end
        entries.select { |entry| entry.status == 'posted' }.each(&:void!)
        batch.transactions.where(status: 'posted').update_all(status: 'reversed', updated_at: Time.current)
        batch.transactions.where(status: 'staged').update_all(status: 'discarded', updated_at: Time.current)
        batch.lines.where(status: 'posted').update_all(status: 'reversed', updated_at: Time.current)
        batch.lines.where(status: 'staged').update_all(status: 'discarded', updated_at: Time.current)
        batch.update!(status: 'reversed', closed_by_name: actor_name(actor), closed_at: Time.current, closed_reason: reason)
        ActivityLogger.log('import_batch_reversed', subject: batch, actor: actor, details: "#{entries.size} journal entr#{entries.size == 1 ? 'y' : 'ies'} voided: #{reason.first(200)}")
        entries.size
      end
    end

    def discard!(batch, actor:)
      raise Error, 'Only a batch that was never approved can be discarded; reverse an approved one.' unless batch.staged?

      ImportBatch.transaction do
        lock_workspace!
        batch.transactions.where(status: %w[staged]).update_all(status: 'discarded', updated_at: Time.current)
        batch.lines.where(status: 'staged').update_all(status: 'discarded', updated_at: Time.current)
        batch.update!(status: 'discarded', closed_by_name: actor_name(actor), closed_at: Time.current, closed_reason: 'Discarded before approval')
        ActivityLogger.log('import_batch_discarded', subject: batch, actor: actor, details: batch.filename)
      end
    end

    private

    def lock_workspace!
      Tenant.unscoped.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
    end

    def actor_name(actor) = actor&.display_name || actor&.email || 'system'

    def approve_list!(batch, actor)
      ImportBatch.transaction do
        lock_workspace!
        case batch.kind
        when 'chart_of_accounts'
          mappings = batch_mappings(batch, 'account').select { |m| m.decision == 'create' && m.target_id.nil? }
          create_accounts!(mappings)
        when 'vendors'
          create_vendors!(batch_mappings(batch, 'vendor').select { |m| m.decision == 'create' && m.target_id.nil? })
        end
        batch.update!(status: 'approved', approved_by_id: actor&.id, approved_by_name: actor_name(actor), approved_at: Time.current)
        ActivityLogger.log('import_batch_approved', subject: batch, actor: actor, details: "#{batch.kind_label}: #{batch.accepted_count} row(s)")
      end
      Result.new(posted: 0, held: {})
    end

    def batch_mappings(batch, entity_type)
      keys = batch.lines.where(status: %w[staged posted]).distinct.pluck(:account_name).map { |n| ImportEntityMapping.key_for(n) }
      ImportEntityMapping.where(entity_type: entity_type, source_key: keys).to_a
    end

    def create_accounts!(mappings)
      mappings.each do |mapping|
        account = Finance::Account.new(code: mapping.proposed_code.to_s.strip, name: mapping.source_name.first(120), account_type: mapping.proposed_type)
        unless account.save
          raise Error, "Could not create the account “#{mapping.source_name}”: #{account.errors.full_messages.to_sentence}. Nothing was changed."
        end
        mapping.update!(decision: 'map', target_id: account.id)
      end
    end

    def create_vendors!(mappings)
      mappings.each do |mapping|
        if Purchasing::Vendor.where('LOWER(name) = ?', mapping.source_name.downcase).exists?
          raise Error, "A vendor named “#{mapping.source_name}” already exists. Map this one to it instead. Nothing was changed."
        end

        vendor = Purchasing::Vendor.create!(name: mapping.source_name.first(200), notes: 'Created from a QuickBooks vendor list import.')
        mapping.update!(decision: 'map', target_id: vendor.id)
      end
    end

    def approve_journal!(batch, actor, post_through, allow_resembling, allow_approved)
      raise Error, 'Choose the last date to post. Later transactions stay staged.' unless post_through.is_a?(Date)

      undecided = undecided_accounts(batch)
      if undecided.any?
        raise Error, "#{undecided.size} account#{'s' unless undecided.size == 1} still need a decision: #{undecided.first(3).map { |r| r[:name] }.to_sentence}#{'…' if undecided.size > 3}. " \
                     'Map each to a Rupert account, create one, or skip it.'
      end

      held = Hash.new(0)
      posted = 0
      ImportBatch.transaction do
        lock_workspace!
        batch.reload
        raise Error, 'This batch has already been closed.' unless %w[staged approved].include?(batch.status)

        mappings = ImportEntityMapping.where(entity_type: 'account').index_by(&:source_key)
        used = account_usage(batch).filter_map { |row| mappings[ImportEntityMapping.key_for(row[:name])] }
        create_accounts!(used.select { |m| m.decision == 'create' && m.target_id.nil? })
        accounts = Finance::Account.where(id: used.filter_map(&:target_id)).index_by(&:id)
        used.select { |m| m.decision == 'map' }.each do |mapping|
          account = accounts[mapping.target_id]
          raise Error, "The Rupert account chosen for “#{mapping.source_name}” no longer exists. Choose again." unless account
          raise Error, "The Rupert account ##{account.code} chosen for “#{mapping.source_name}” is archived. Choose an active one." unless account.active
        end

        ranges = approved_ranges
        batch.transactions.where(status: 'staged').includes(:lines).order(:txn_date, :id).each do |txn|
          reason = hold_reason(txn, post_through, allow_resembling, allow_approved, ranges, mappings)
          if reason
            held[reason.first] += 1
            # A look-alike flag survives other holds, so it is still asked about once they clear.
            txn.update_columns(reason: reason.last, updated_at: Time.current) unless txn.reason.to_s.start_with?('Resembles')
            next
          end
          entry = post_transaction(txn, mappings, batch, actor)
          if entry.is_a?(String)
            held['the ledger refused it'] += 1
            txn.update_columns(reason: "The ledger refused this transaction: #{entry}", updated_at: Time.current)
          else
            posted += 1
          end
        end
        next if posted.zero? && batch.staged?

        batch.update!(status: 'approved', post_through: post_through, approved_by_id: actor&.id, approved_by_name: actor_name(actor), approved_at: batch.approved_at || Time.current)
        ActivityLogger.log('import_batch_approved', subject: batch, actor: actor,
          details: "#{posted} transaction(s) posted through #{post_through}; #{held.values.sum} held")
      end
      Result.new(posted: posted, held: held)
    end

    def hold_reason(txn, post_through, allow_resembling, allow_approved, ranges, mappings)
      if txn.txn_date > post_through
        return ['after the chosen date', "Dated after the chosen last date (#{post_through}); left staged."]
      end
      if txn.reason.to_s.start_with?('Resembles') && !allow_resembling
        return ['resembles an earlier import', txn.reason]
      end
      if (lock = PeriodLock.lock_covering(txn.txn_date))
        return ['in a locked period', "#{lock.label} is locked. Unlock it on the Books desk, then approve again to post this."]
      end
      if !allow_approved && ranges.any? { |from, to| txn.txn_date.between?(from, to) }
        return ['in an approved period', 'Falls in a day or week whose books were approved. Posting would show that approval as changed; tick the acknowledgement to post it.']
      end
      skipped = txn.lines.map(&:account_name).uniq.find { |name| mappings[ImportEntityMapping.key_for(name)]&.decision == 'skip' }
      return ['uses a skipped account', "Uses the account “#{skipped}”, which you chose to skip."] if skipped

      nil
    end

    # Returns the entry, or the failure message as a String.
    def post_transaction(txn, mappings, batch, actor)
      lines = txn.lines.sort_by(&:row_no).filter_map do |line|
        next unless line.status == 'staged'

        mapping = mappings.fetch(ImportEntityMapping.key_for(line.account_name))
        { account_id: mapping.target_id, debit_cents: line.debit_cents, credit_cents: line.credit_cents, memo: line.memo&.first(300) }
      end
      memo = ['QuickBooks', txn.txn_type, txn.doc_number.presence&.then { |n| "##{n}" }, txn.name.presence&.then { |n| "· #{n}" }].compact.join(' ').first(240)
      entry = nil
      Finance::JournalEntry.transaction(requires_new: true) do
        entry = Finance::JournalEntry.post!(kind: 'imported', posted_on: txn.txn_date, lines: lines, memo: "#{memo} (import batch ##{batch.id})",
          source_type: 'ImportTransaction', source_id: txn.id, created_by: actor)
        txn.update_columns(status: 'posted', journal_entry_id: entry.id, posted_at: Time.current, reason: nil, updated_at: Time.current)
        txn.lines.where(status: 'staged').update_all(status: 'posted', updated_at: Time.current)
      end
      entry
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      e.respond_to?(:record) && e.record ? e.record.errors.full_messages.to_sentence : 'it was already posted'
    end
  end
end
