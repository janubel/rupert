# frozen_string_literal: true

module Finance
  # Presence and observed date ranges, never a claim of complete source history.
  class SourceCoverage
    def initialize(from:, to:)
      @from, @to = from, to
      zone = Time.find_zone!(MoneyReconciliationReport::ZONE)
      @range = zone.local(from.year, from.month, from.day)...zone.local((to + 1).year, (to + 1).month, (to + 1).day)
    end

    def rows
      @rows ||= [
        summarize('ctrax', 'C-Trax', 'Retail sales and register controls', CtraxDay.all, :business_date,
          'store-day snapshots', last_read: CtraxDay.maximum(:captured_at)),
        summarize('square', 'Square', 'POS orders and recorded tenders', Core::Order.where(source: 'square'), :occurred_at,
          'orders', last_read: CatalogSyncHistory.watermark('square')),
        summarize('shopify', 'Shopify', 'Online orders; some tenders are inferred', Core::Order.where(source: 'shopify'), :occurred_at,
          'orders', last_read: CatalogSyncHistory.watermark('shopify')),
        summarize('swipesimple', 'SwipeSimple', 'Payment transactions; invoices are separate evidence',
          SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' }), :occurred_at,
          'transaction observations', last_read: PosConnection.find_by(provider: 'swipesimple')&.last_reported_at)
      ]
    end

    private

    def summarize(key, label, role, scope, column, unit, last_read:)
      period = column == :business_date ? @from..@to : @range
      first_at, last_at = scope.minimum(column), scope.maximum(column)
      { 'key' => key, 'label' => label, 'role' => role, 'unit' => unit,
        'period_records' => scope.where(column => period).count, 'stored_records' => scope.count,
        'first_date' => date(first_at), 'last_date' => date(last_at), 'last_read' => last_read&.iso8601 }
    end

    def date(value)
      return unless value

      (value.is_a?(Time) ? value.in_time_zone(MoneyReconciliationReport::ZONE).to_date : value.to_date).iso8601
    end
  end
end
