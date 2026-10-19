# frozen_string_literal: true

module Finance
  # Reconciles uploaded bank statement lines against the general ledger's
  # bank-side accounts (roadmap F40). Read-only: it suggests matches by sign,
  # amount and date proximity but never writes — a person confirms each pairing
  # in the workbench. Unmatched items on both sides are the point: they surface
  # money that moved in the bank with no ledger entry (e.g. unposted expenses)
  # and ledger movements that never hit the statement.
  #
  # Sign convention: a statement line is positive for money in, negative for
  # money out. A ledger movement is signed debit-minus-credit on a bank account,
  # so a receipt (debit to Cash) is positive and a payment (credit to Checking)
  # is negative — the two line up directly.
  class BankReconciliation
    BANK_ACCOUNT_CODES = %w[1000 1100].freeze # Cash, Checking
    DEFAULT_WINDOW_DAYS = 5

    Suggestion = Struct.new(:line, :entry, :amount_cents, :days_apart, keyword_init: true)

    attr_reader :account_label, :from, :to, :window_days

    def initialize(account_label:, from:, to:, window_days: DEFAULT_WINDOW_DAYS)
      @account_label = account_label
      @from = from
      @to = to
      @window_days = window_days.to_i.clamp(0, 31)
    end

    def lines
      @lines ||= BankStatementLine.where(account_label: account_label, posted_on: from..to)
                                  .where.not(status: 'ignored')
                                  .order(:posted_on, :line_no).to_a
    end

    # Posted ledger movements against bank accounts in the window, each signed
    # debit-minus-credit, tagged with the entry and its date.
    def gl_movements
      @gl_movements ||= begin
        account_ids = Finance::Account.where(code: BANK_ACCOUNT_CODES).pluck(:id)
        JournalLine.joins(:journal_entry).merge(JournalEntry.posted)
                   .where(account_id: account_ids)
                   .where(journal_entries: { posted_on: from..to })
                   .includes(:journal_entry)
                   .map do |line|
          {
            entry: line.journal_entry,
            signed_cents: line.debit_cents.to_i - line.credit_cents.to_i,
            date: line.journal_entry.posted_on
          }
        end
      end
    end

    # Greedy sign + amount + date-window matching. Lines already linked to an
    # entry keep that pairing; the rest get a best suggestion. Each ledger
    # movement is claimed at most once.
    def suggestions
      @suggestions ||= begin
        claimed = Set.new
        result = {}

        # Honour existing confirmed links first.
        lines.each do |line|
          next unless line.journal_entry_id

          entry = existing_entry(line)
          next unless entry

          result[line.id] = entry
          # Claim one movement of the linked entry (the leg equal to the line,
          # else its first unclaimed leg) so a compound entry's other bank leg
          # stays available and visible.
          legs = gl_movements.each_index.select { |index| gl_movements[index][:entry].id == entry.entry.id && !claimed.include?(index) }
          leg = legs.find { |index| gl_movements[index][:signed_cents] == line.amount_cents } || legs.first
          claimed << leg if leg
        end

        lines.each do |line|
          next if result.key?(line.id)
          next unless line.pending? || line.status == 'matched'

          candidate = gl_movements.each_with_index.find do |movement, index|
            next false if claimed.include?(index)
            next false unless movement[:entry].id != line.journal_entry_id

            same_sign(movement[:signed_cents], line.amount_cents) &&
              movement[:signed_cents].abs == line.amount_cents.abs &&
              (movement[:date] - line.posted_on).abs <= window_days
          end
          next unless candidate

          movement, index = candidate
          claimed << index
          result[line.id] = Suggestion.new(line: line, entry: movement[:entry],
            amount_cents: line.amount_cents,
            days_apart: (movement[:date] - line.posted_on).abs)
        end
        @claimed_movements = claimed
        result
      end
    end

    # Indexes into gl_movements that back a confirmed or suggested match.
    def claimed_movements
      suggestions
      @claimed_movements
    end

    def matched_lines = lines.select { |l| suggestions.key?(l.id) }
    def unmatched_lines = lines.reject { |l| suggestions.key?(l.id) }

    # Near-duplicate statement lines: same amount within the date window, which
    # the exact-fingerprint dedupe at import would not catch (e.g. a deposit
    # that appears twice with a slightly different description, or a double
    # charge). Ignored lines are excluded. Each group has 2+ lines.
    def duplicate_groups
      active = lines.reject { |l| l.status == 'ignored' }
      active.group_by(&:amount_cents).filter_map do |_amount, group|
        next if group.size < 2

        clusters = [[]]
        group.sort_by(&:posted_on).each do |line|
          last = clusters.last.last
          if last && (line.posted_on - last.posted_on).abs <= window_days
            clusters.last << line
          else
            clusters << [line]
          end
        end
        clusters.select { |c| c.size > 1 }
      end.flatten(1)
    end

    def matched_entry_ids = suggestions.values.filter_map { |s| s.is_a?(Suggestion) ? s.entry.id : s&.id }
    def unmatched_gl = gl_movements.reject.with_index { |_movement, index| claimed_movements.include?(index) }

    def summary
      stmt_in = lines.select { |l| l.amount_cents.positive? }.sum(&:amount_cents)
      stmt_out = lines.select { |l| l.amount_cents.negative? }.sum(&:amount_cents)
      gl_in = gl_movements.select { |m| m[:signed_cents].positive? }.sum { |m| m[:signed_cents] }
      gl_out = gl_movements.select { |m| m[:signed_cents].negative? }.sum { |m| m[:signed_cents] }
      {
        lines: lines.size,
        matched: matched_lines.size,
        unmatched_lines: unmatched_lines.size,
        unmatched_gl: unmatched_gl.size,
        statement_in_cents: stmt_in,
        statement_out_cents: stmt_out,
        statement_net_cents: stmt_in + stmt_out,
        gl_in_cents: gl_in,
        gl_out_cents: gl_out,
        gl_net_cents: gl_in + gl_out,
        difference_cents: (stmt_in + stmt_out) - (gl_in + gl_out)
      }
    end

    def bank_accounts
      Finance::Account.where(code: BANK_ACCOUNT_CODES).ordered
    end

    private

    def same_sign(a, b) = (a.positive? && b.positive?) || (a.negative? && b.negative?)

    def existing_entry(line)
      entry = JournalEntry.find_by(id: line.journal_entry_id)
      return nil unless entry

      Suggestion.new(line: line, entry: entry, amount_cents: line.amount_cents, days_apart: 0)
    end
  end
end
