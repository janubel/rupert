# frozen_string_literal: true

module Finance
  # Catches the ledger up with completed payments and refunds that have no
  # posted entry. The live hook (Core::Payment / Core::Refund) keeps new ones
  # current; this covers whatever came before it or failed while it ran. It is
  # a dry run unless asked to post: `plan` changes nothing, `apply!` posts one
  # record at a time and reports what a locked period or a missing account
  # refused instead of stopping.
  class SalesBackfill
    Row = Struct.new(:month, :kind, :count, :amount_cents, keyword_init: true)
    Result = Struct.new(:posted, :refused, keyword_init: true)

    def initialize(created_by: nil)
      @created_by = created_by
    end

    # Unposted records grouped by month, for the owner to review before posting.
    def plan
      rows(Posting.unposted_sales, 'paid_at', 'sale') + rows(Posting.unposted_refunds, 'refunded_at', 'refund')
    end

    def apply!
      result = Result.new(posted: 0, refused: [])
      Posting.unposted_sales.find_each { |payment| post(result) { Posting.sync_sale(payment, created_by: @created_by) } }
      Posting.unposted_refunds.find_each { |refund| post(result) { Posting.sync_refund(refund, created_by: @created_by) } }
      result
    end

    private

    def rows(scope, column, kind)
      scope.group("substr(#{column}, 1, 7)").order(Arel.sql("substr(#{column}, 1, 7)"))
           .pluck(Arel.sql("substr(#{column}, 1, 7)"), Arel.sql('COUNT(*)'), Arel.sql('SUM(amount_cents)'))
           .map { |month, count, cents| Row.new(month: month, kind: kind, count: count, amount_cents: cents.to_i) }
    end

    def post(result)
      yield
      result.posted += 1
    rescue Posting::Error, ActiveRecord::RecordInvalid => e
      result.refused << e.message
    end
  end
end
