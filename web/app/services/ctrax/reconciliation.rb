# frozen_string_literal: true

module Ctrax
  class Reconciliation
    attr_reader :day

    def initialize(day)
      @day = day
    end

    def orders
      day.orders.select { |row| row['status'] == 'completed' && !row['deleted'] }
    end

    def payments
      orders.flat_map { |row| row['payments'] }.select { |row| row['status'] == 'completed' && !row['deleted'] }
    end

    def sum(rows, key)
      values = rows.map { |row| row[key] }
      values.any?(&:nil?) ? nil : values.sum
    end

    def checks
      result = [['Completed orders', orders.size, day.controls['order_count'], false]]
      { 'Order total' => %w[total orders_totals_sum], 'Tax' => %w[tax orders_taxes_sum],
        'Discounts' => %w[discount orders_discounts_sum], 'Tips' => %w[tip orders_tips_sum] }.each do |label, (key, control)|
        result << [label, sum(orders, key), day.controls[control], true]
      end
      %w[cash credit standaloneCardTerminal loyalty gift_card].each do |type|
        result << ["#{type} tender", sum(payments.select { |p| p['type'] == type }, 'amount'),
                   day.controls["#{type}_payments_amount_sum"], true]
      end
      result.map do |label, actual, expected, monetary|
        { label: label, actual: actual, expected: expected, monetary: monetary,
          delta: actual.nil? || expected.nil? ? nil : actual - expected }
      end
    end

    def warnings
      result = []
      result << 'Source refunds need separate review; no restocking or processor refund is performed.' if day.controls['refund_count'].to_i.positive? || orders.any? { |row| row['refund_count'].positive? }
      result << 'Some payment states or tender types require review.' if orders.flat_map { |o| o['payments'] }.any? { |p| p['status'] != 'completed' || p['deleted'] || !%w[cash credit standaloneCardTerminal loyalty gift_card].include?(p['type']) }
      result << 'Some source money fields are missing.' if checks.any? { |check| check[:delta].nil? }
      result << 'Order and payment base amounts differ.' if orders.any? { |o| sum(o['payments'].select { |p| p['status'] == 'completed' && !p['deleted'] }, 'amount') != o['total'] }
      result << 'Payment totals, tips or surcharges need review.' if payments.any? { |p| [p['total_amount'], p['amount'], p['tip_amount'], p['surcharge_amount']].any?(&:nil?) || p['total_amount'] != p['amount'] + p['tip_amount'] + p['surcharge_amount'] }
      result
    end

    def matched?
      warnings.empty? && checks.all? { |check| check[:delta] == 0 }
    end

    def session_rows
      zone = Time.find_zone!(day.timezone)
      start = zone.local(day.business_date.year, day.business_date.month, day.business_date.day)
      finish = start.advance(days: 1)
      day.sessions.map do |session|
        own_orders = orders.select { |order| order['register_session_id'] == session['id'] }
        cash = sum(own_orders.flat_map { |o| o['payments'] }.select { |p| p['type'] == 'cash' && p['status'] == 'completed' && !p['deleted'] }, 'amount')
        drops = sum(session['cash_drops'], 'amount')
        cash_additions_unknown = own_orders.flat_map { |o| o['payments'] }.any? { |p| p['type'] == 'cash' && (p['tip_amount'] != 0 || p['surcharge_amount'] != 0) }
        complete = !cash_additions_unknown && session['closed_at'] && Time.iso8601(session['opened_at']) >= start &&
                   Time.iso8601(session['closed_at']) <= finish && day.controls['cash_refunds_amount_sum'] == 0 &&
                   matched? && [cash, drops, session['opening_cash'], session['closing_cash']].none?(&:nil?) &&
                   session['cash_drops'].all? { |drop| drop['amount'] && drop['amount'] >= 0 }
        expected = complete ? session['opening_cash'] + cash - drops : nil
        session.merge('day_cash' => cash, 'drop_total' => drops, 'expected_cash' => expected,
          'variance' => expected.nil? ? nil : session['closing_cash'] - expected)
      end
    end
  end
end
