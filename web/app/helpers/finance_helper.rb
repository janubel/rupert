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
  def finance_balance_status(difference_cents, balanced_text: 'Balanced')
    if difference_cents.to_i.zero?
      content_tag(:p, "#{balanced_text}: no difference.",
                  class: 'balance-status balance-ok', role: 'status', data: { balance: 'ok' })
    else
      content_tag(:p, "Out of balance by #{finance_money_text(difference_cents.to_i.abs)}.",
                  class: 'balance-status balance-bad', role: 'status', data: { balance: 'bad' })
    end
  end

  # Spreadsheet-safe text: a cell that starts with = + - @ tab or CR would be
  # run as a formula by Excel/Sheets, so it is prefixed with an apostrophe.
  def self.csv_safe(value)
    text = value.to_s
    text.match?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
  end
end
