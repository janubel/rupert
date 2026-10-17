# frozen_string_literal: true

# One row per transaction in a portal export, so a day or period reads only the
# observations it can cover. The original row stays encrypted and is returned
# exactly as the export recorded it.
class AuthorizeNetPortalObservation < ApplicationRecord
  include TenantScoped
  SLICE = 500
  belongs_to :authorize_net_portal_export
  encrypts :record_json

  # Replaces an export's observations; safe to repeat.
  def self.record!(export)
    unscoped.where(authorize_net_portal_export_id: export.id).delete_all
    rows = JSON.parse(export.records_json).map.with_index do |row, position|
      { tenant_id: export.tenant_id, authorize_net_portal_export_id: export.id, position: position, gateway_id: export.gateway_id,
        transaction_id: row.fetch('transaction_id').to_s, exported_at: export.exported_at,
        submitted_at: instant(row['submitted_at']), settled_at: instant(row['settled_at']),
        status: row['status'], transaction_type: row['transaction_type'], currency: row['currency'],
        settlement_cents: row['settlement_cents'].is_a?(Integer) ? row['settlement_cents'] : nil, record_json: row.to_json }
    end
    rows.each_slice(SLICE) { |slice| unscoped.insert_all!(slice) }
  end

  def self.instant(value)
    Time.iso8601(value) if value.is_a?(String) && value.present?
  rescue ArgumentError
    nil
  end

  # Newest observation per gateway and transaction for the keys whose
  # submitted or settled time falls in range.
  def self.latest_between(range)
    latest_for(where(submitted_at: range).or(where(settled_at: range)).distinct.pluck(:gateway_id, :transaction_id))
  end

  # Newest exported_at wins per gateway and transaction; ties keep the later
  # export and row. Order is first appearance by export and row, as the
  # original whole-history scan produced.
  def self.latest_for(keys)
    keys = keys.to_set
    return [] if keys.empty?

    observed = keys.map(&:last).uniq.each_slice(SLICE).flat_map do |ids|
      where(transaction_id: ids).pluck(:id, :authorize_net_portal_export_id, :position, :gateway_id, :transaction_id, :exported_at)
    end
    winners = observed.select { |row| keys.include?(row.values_at(3, 4)) }.sort_by { |row| row.values_at(1, 2) }
      .each_with_object({}) do |(id, export_id, _position, gateway, transaction, exported_at), latest|
        stamp = exported_at.iso8601(6)
        previous = latest[[gateway, transaction]]
        next if previous && previous.last > stamp

        latest[[gateway, transaction]] = [id, gateway, export_id, stamp]
      end.values
    records = winners.map(&:first).each_slice(SLICE).flat_map { |ids| where(id: ids).pluck(:id, :record_json) }.to_h
    winners.map do |id, gateway, export_id, stamp|
      JSON.parse(records.fetch(id)).merge('gateway_id' => gateway, 'export_id' => export_id, 'exported_at' => stamp)
    end
  end

  def self.latest_all
    latest_for(distinct.pluck(:gateway_id, :transaction_id))
  end

  def self.transaction_count
    unscoped.from(select(:gateway_id, :transaction_id).distinct, :keys).count
  end

  # Each transaction's newest observation, ranked in SQL by export time, then
  # the later export and row.
  def self.newest
    ranked = select(:gateway_id, :transaction_id, :submitted_at, :currency, :status, :transaction_type, :settlement_cents,
      Arel.sql('ROW_NUMBER() OVER (PARTITION BY gateway_id, transaction_id ' \
               'ORDER BY exported_at DESC, authorize_net_portal_export_id DESC, position DESC) AS latest_rank'))
    unscoped.from(ranked, :ranked).where('ranked.latest_rank = 1')
  end

  # Index page window: the most recently submitted transactions, newest first.
  def self.recent(limit)
    keys = newest.where('ranked.submitted_at IS NOT NULL').order('ranked.submitted_at DESC').limit(limit)
      .pluck('ranked.gateway_id', 'ranked.transaction_id')
    latest_for(keys).sort_by { |row| row.fetch('submitted_at') }.reverse
  end

  # Settlement cents by currency over each transaction's newest observation.
  def self.latest_totals(status:, transaction_type:)
    newest.where('ranked.status = ? AND ranked.transaction_type = ?', status, transaction_type)
      .group('ranked.currency').order('ranked.currency').sum('ranked.settlement_cents').transform_values(&:to_i)
  end
end
