# frozen_string_literal: true

module Marketing
  module ShopifyDiscountTerms
    FIELDS = %i[code kind value minimum_subtotal usage_limit once_per_customer starts_at ends_at].freeze

    def self.build(attributes, title:)
      kind = attributes[:kind]
      raise ReplyWorkflow::Invalid, 'Choose percentage or fixed amount.' unless %w[percentage fixed].include?(kind)

      value = decimal(attributes[:value])
      minimum = decimal(attributes[:minimum_subtotal].presence || '0')
      unless value.positive? && (kind != 'percentage' || value <= 100) && minimum >= 0
        raise ReplyWorkflow::Invalid, 'Enter a positive discount (up to 100%) and a nonnegative minimum spend.'
      end
      limit = attributes[:usage_limit].to_s
      unless limit.match?(/\A[1-9]\d{0,6}\z/) && limit.to_i <= 1_000_000
        raise ReplyWorkflow::Invalid, 'Set a total usage limit between 1 and 1,000,000.'
      end
      once = attributes[:once_per_customer].to_s
      raise ReplyWorkflow::Invalid, 'Choose the per-customer usage rule.' unless %w[0 1].include?(once)

      starts = time(attributes[:starts_at])
      ends = time(attributes[:ends_at])
      unless starts && ends && ends > starts && ends > Time.current
        raise ReplyWorkflow::Invalid, 'Set an expiry after the start date and the current time.'
      end
      benefit = kind == 'percentage' ? { 'percentage' => (value / 100).to_f } : { 'discountAmount' => { 'amount' => value.to_s('F'), 'appliesOnEachItem' => false } }
      input = { 'title' => title, 'code' => attributes[:code].to_s.strip.upcase,
                'startsAt' => starts.utc.iso8601, 'endsAt' => ends.utc.iso8601,
                'context' => { 'all' => true }, 'usageLimit' => limit.to_i, 'appliesOncePerCustomer' => once == '1',
                'combinesWith' => { 'orderDiscounts' => false, 'productDiscounts' => false, 'shippingDiscounts' => false },
                'customerGets' => { 'items' => { 'all' => true }, 'value' => benefit, 'appliesOnOneTimePurchase' => true, 'appliesOnSubscription' => false } }
      input['minimumRequirement'] = { 'subtotal' => { 'greaterThanOrEqualToSubtotal' => minimum.to_s('F') } } if minimum.positive?
      input
    end

    def self.summary(input, currency)
      value = input.fetch('customerGets').fetch('value')
      benefit = value['percentage'] ? "#{(BigDecimal(value['percentage'].to_s) * 100).to_s('F')}%" : "#{value.dig('discountAmount', 'amount')} #{currency}"
      minimum = input.dig('minimumRequirement', 'subtotal', 'greaterThanOrEqualToSubtotal') || '0'
      "#{benefit} off all products on one-time purchases; all customers; minimum subtotal #{minimum} #{currency}; " \
        "#{input['usageLimit']} total uses; #{input['appliesOncePerCustomer'] ? 'once per customer' : 'repeat customer use allowed'}; " \
        'no combining with product, order or shipping discounts. Excludes subscriptions and shipping charges.'
    end

    def self.matches?(record, node)
      return false unless node.is_a?(Hash) && node['id'].to_s.match?(%r{\Agid://shopify/DiscountCodeNode/\d+\z})
      return false if record.remote_id.present? && node['id'] != record.remote_id

      actual = node.fetch('codeDiscount', {})
      expected = record.input
      gets = actual.fetch('customerGets', {})
      return false unless actual['__typename'] == 'DiscountCodeBasic' && actual['title'] == expected['title'] &&
        actual.dig('codes', 'nodes') == [{ 'code' => expected['code'] }] && actual.dig('codes', 'pageInfo', 'hasNextPage') == false &&
        actual.dig('context', '__typename') == 'DiscountBuyerSelectionAll' && gets.dig('items', '__typename') == 'AllDiscountItems' &&
        gets['appliesOnOneTimePurchase'] == true && gets['appliesOnSubscription'] == false &&
        actual['combinesWith'] == expected['combinesWith'] && actual['usageLimit'] == expected['usageLimit'] &&
        actual['appliesOncePerCustomer'] == expected['appliesOncePerCustomer'] &&
        time(actual['startsAt']) == time(expected['startsAt']) && time(actual['endsAt']) == time(expected['endsAt'])

      benefit = expected.dig('customerGets', 'value')
      value = gets.fetch('value', {})
      benefit_matches = if benefit.key?('percentage')
        value['__typename'] == 'DiscountPercentage' && BigDecimal(value['percentage'].to_s) == BigDecimal(benefit['percentage'].to_s)
      else
        value['__typename'] == 'DiscountAmount' && value['appliesOnEachItem'] == false && value.dig('amount', 'currencyCode') == record.currency &&
          BigDecimal(value.dig('amount', 'amount').to_s) == BigDecimal(benefit.dig('discountAmount', 'amount'))
      end
      minimum = expected.dig('minimumRequirement', 'subtotal', 'greaterThanOrEqualToSubtotal')
      requirement = actual['minimumRequirement']
      minimum_matches = if minimum
        requirement&.dig('__typename') == 'DiscountMinimumSubtotal' && requirement.dig('greaterThanOrEqualToSubtotal', 'currencyCode') == record.currency &&
          BigDecimal(requirement.dig('greaterThanOrEqualToSubtotal', 'amount').to_s) == BigDecimal(minimum)
      else
        requirement.nil?
      end
      benefit_matches && minimum_matches
    rescue ArgumentError, TypeError, NoMethodError
      false
    end

    def self.decimal(value)
      raise ReplyWorkflow::Invalid, 'Use decimal amounts with at most two decimal places.' unless value.to_s.match?(/\A\d{1,8}(?:\.\d{1,2})?\z/)

      BigDecimal(value.to_s)
    end

    def self.time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
