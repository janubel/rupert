# frozen_string_literal: true

# Money and status display for the Money workspace (finance, close, books).
# Amounts are always integer cents; nothing here rounds, converts or sums.
module FinanceHelper
  MINUS = '−'

  # Plain-text amount: "$1,234.56", "−$0.01", "CAD 5.00". A nil amount is
  # missing, not zero, and reads as +missing+ ("—" unless overridden).
  # zero: :dash shows "—" for an exact zero (debit/credit columns).
  def finance_money_text(cents, currency: 'USD', zero: :show, missing: '—')
    return missing if cents.nil?

    cents = Integer(cents)
    return '—' if cents.zero? && zero == :dash

    whole, fraction = cents.abs.divmod(100)
    digits = "#{number_with_delimiter(whole)}.#{format('%02d', fraction)}"
    prefix = currency == 'USD' ? '$' : "#{currency.presence || 'Unknown currency'} "
    "#{cents.negative? ? MINUS : ''}#{prefix}#{digits}"
  end

  # HTML amount with tabular digits. Negatives carry a real minus sign and a
  # red class, so the colour is never the only signal.
  def finance_money(cents, currency: 'USD', zero: :show, missing: '—')
    text = finance_money_text(cents, currency: currency, zero: zero, missing: missing)
    classes = ['money']
    classes << 'money-missing' if cents.nil?
    classes << 'money-negative' if !cents.nil? && Integer(cents).negative?
    content_tag(:span, text, class: classes.join(' '))
  end

  # Account code and name always travel together.
  def finance_account_label(account)
    "#{account.code} · #{account.name}"
  end

  # Plain-language balance status for a report. +difference_cents+ is the
  # debit total minus the credit total (or assets minus liabilities+equity).
  def finance_balance_status(difference_cents, balanced_text: 'Balanced: no difference')
    if difference_cents.to_i.zero?
      content_tag(:p, "#{balanced_text}.",
        class: 'balance-status balance-ok', role: 'status', data: { balance: 'ok' })
    else
      content_tag(:p, "Out of balance by #{finance_money_text(difference_cents.to_i.abs)}.",
        class: 'balance-status balance-bad', role: 'status', data: { balance: 'bad' })
    end
  end

  # Exact decimal for CSV: 12550 -> "125.50". No floats.
  def self.cents_to_decimal(cents)
    return '' if cents.nil?

    whole, fraction = Integer(cents).abs.divmod(100)
    "#{'-' if Integer(cents).negative?}#{whole}.#{format('%02d', fraction)}"
  end

  # Active period locks as JSON for form scripts: [{from:, to:, label:}].
  # The server re-checks every date; this only warns before submitting.
  def finance_locks_json
    PeriodLock.active_locks.map { |l| { from: l.period_from.iso8601, to: l.period_to.iso8601, label: l.label } }.to_json
  end

  # The lock covering a date, for read-only notices on existing records.
  def finance_lock_for(date)
    date.present? ? PeriodLock.lock_covering(date) : nil
  end

  ACTION_LABELS = {
    'expense_recorded' => 'Recorded', 'vendor_payment' => 'Recorded',
    'expense_updated' => 'Edited',
    'expense_deleted' => 'Removed', 'payment_deleted' => 'Removed',
    'expense_restored' => 'Restored', 'payment_restored' => 'Restored'
  }.freeze

  # Who did what to a register record, oldest first, as plain sentences. The
  # first line always exists: records saved before the audit trail was kept
  # say so instead of implying a person.
  def finance_history(record, logs)
    events = Array(logs).filter_map do |log|
      label = ACTION_LABELS[log.action]
      next unless label

      "#{label} #{log.created_at.in_time_zone.strftime('%b %-d, %Y %-I:%M %p')} by #{log.actor_name.presence || 'the system'}"
    end
    unless Array(logs).any? { |log| ACTION_LABELS[log.action] == 'Recorded' }
      events.unshift("Recorded #{record.created_at.in_time_zone.strftime('%b %-d, %Y')} (author not recorded)")
    end
    events
  end

  # The narrowest active lock covering a date, from a preloaded list.
  def finance_lock_in(locks, date)
    return nil if date.blank?

    Array(locks).select { |l| l.period_from <= date && date <= l.period_to }.min_by { |l| l.period_to - l.period_from }
  end

  # Confirmation text for removing a register record: names the amount, who
  # and when, and what happens next.
  def finance_remove_confirm(noun, cents, who, date, ledger: true)
    effect = ledger ? 'Its ledger entry is voided (kept on record as void).' : 'It stays visible as Removed.'
    "Remove this #{noun}?\n\nAmount: #{finance_money_text(cents)}\n#{noun == "expense" ? "Payee" : "Vendor"}: #{who.presence || '(none)'}\n" \
      "Date: #{date}\n\n#{effect} It no longer counts in totals, and you can restore it from the Removed row."
  end

  # Spreadsheet-safe text: a cell that starts with = + - @ tab or CR would be
  # run as a formula by Excel/Sheets, so it is prefixed with an apostrophe.
  def self.csv_safe(value)
    text = value.to_s
    text.match?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
  end
end
