# frozen_string_literal: true

# A bounded metadata-only view across the vault and retained native CSVs.
class ReconciliationLibrary
  Error = Class.new(ArgumentError)
  PAGE_SIZE = 24
  CATEGORIES = { 'all' => 'All documents', 'invoices' => 'Invoices', 'controls' => 'Register controls',
    'source_files' => 'Source files', 'archives' => 'Report archives', 'native_exports' => 'Native exports' }.freeze
  SOURCE_NAMES = { 'shopify' => 'Shopify', 'square' => 'Square', 'swipesimple' => 'SwipeSimple', 'ctrax' => 'C-Trax',
    'cash_app' => 'Cash App', 'authorize_net' => 'Authorize.net', 'iris' => 'NAB / IRIS', 'bank' => 'Bank', 'other' => 'Other', 'rupert' => 'Rupert' }.freeze
  Entry = Struct.new(:record, :rank, :retained_at, :key, keyword_init: true)
  attr_reader :filters

  def initialize(params = {})
    @filters = params.to_h.stringify_keys.slice('q', 'source', 'category', 'from', 'to').transform_values { |value| value.to_s.strip }
    @filters['category'] = 'all' if @filters['category'].blank?
    raise Error, 'Choose a document category from the list.' unless CATEGORIES.key?(@filters['category'])
    raise Error, 'Choose a source from the list.' if @filters['source'].present? && !SOURCE_NAMES.key?(@filters['source'])
    raise Error, 'Keep the search to 100 characters or fewer.' if @filters['q'].to_s.length > 100

    @from = parse_date(@filters['from'])
    @to = parse_date(@filters['to'])
    raise Error, 'The end date must be on or after the start date.' if @from && @to && @from > @to

    if params[:cursor].present?
      @cursor = verifier.verified(params[:cursor], purpose: fingerprint)
      raise Error, 'This page link has expired. Showing the newest matching files.' unless @cursor
    end
  end

  def total
    @total ||= relations.sum { |relation, _, _, _| relation.count(:all) }
  end

  def entries
    @entries ||= relations.flat_map do |relation, rank, time_column, prefix|
      after_cursor(relation, rank, time_column).order(time_column => :desc, id: :desc).limit(PAGE_SIZE + 1).map do |record|
        Entry.new(record: record, rank: rank, retained_at: record.public_send(time_column), key: "#{prefix}:#{record.id}")
      end
    end.sort_by { |entry| [-entry.retained_at.to_f, entry.rank, -entry.record.id] }
  end

  def page
    entries.first(PAGE_SIZE)
  end

  def next_cursor
    return unless entries.size > PAGE_SIZE

    last = page.last
    verifier.generate([last.retained_at.iso8601(6), last.rank, last.record.id], purpose: fingerprint, expires_in: 1.day)
  end

  private

  def relations
    @relations ||= begin
      vault = ReconciliationDocument.select(:id, :source, :kind, :filename, :period_from, :period_to,
        :created_at, :metadata_json, :supersedes_id, :sha256, :byte_size)
      vault = vault.where(source: filters['source']) if filters['source'].present?
      vault = vault.where('period_to >= ?', @from) if @from
      vault = vault.where('period_from <= ?', @to) if @to
      kinds = { 'invoices' => ['invoice'], 'controls' => ['register_control'], 'source_files' => ['source_export'],
        'archives' => %w[daily_archive period_archive], 'native_exports' => [] }[filters['category']]
      vault = vault.where(kind: kinds) if kinds
      if filters['q'].present?
        sources = SOURCE_NAMES.filter_map { |key, name| key if name.downcase.include?(filters['q'].downcase) }
        vault = vault.where("LOWER(filename) LIKE :q ESCAPE '!' OR LOWER(kind) LIKE :q ESCAPE '!' OR source IN (:sources) OR id = :id",
          q: pattern, sources: sources, id: reference_id)
      end
      result = [[vault, 0, :created_at, 'document']]
      [['swipesimple', SwipesimpleExport, 1], ['authorize_net', AuthorizeNetPortalExport, 2]].each do |source, model, rank|
        next if filters['source'].present? && filters['source'] != source
        next unless %w[all invoices native_exports].include?(filters['category'])
        next if filters['category'] == 'invoices' && source != 'swipesimple'

        native = model.select(:id, :kind, :exported_at, :sha256)
        native = native.where(kind: 'invoices') if filters['category'] == 'invoices'
        native = native.where('exported_at >= ?', @from.in_time_zone.beginning_of_day) if @from
        native = native.where('exported_at < ?', (@to + 1).in_time_zone.beginning_of_day) if @to
        if filters['q'].present? && !SOURCE_NAMES.fetch(source).downcase.include?(filters['q'].downcase)
          native = native.where("LOWER(kind) LIKE :q ESCAPE '!' OR id = :id", q: pattern, id: reference_id)
        end
        result << [native, rank, :exported_at, source]
      end
      result
    end
  end

  def after_cursor(relation, rank, column)
    return relation unless @cursor

    timestamp, cursor_rank, id = @cursor
    stamp = Time.iso8601(timestamp)
    if rank < cursor_rank
      relation.where("#{column} < ?", stamp)
    elsif rank > cursor_rank
      relation.where("#{column} <= ?", stamp)
    else
      relation.where("#{column} < ? OR (#{column} = ? AND id < ?)", stamp, stamp, id)
    end
  end

  def parse_date(value)
    return if value.blank?

    ReconciliationEvidence.dates(value, value).first
  rescue ReconciliationEvidence::Error
    raise Error, 'Choose valid start and end dates.'
  end

  def pattern
    "%#{ActiveRecord::Base.sanitize_sql_like(filters['q'].downcase, '!')}%"
  end

  def reference_id
    filters['q'].to_s.match?(/\A#?\d+\z/) ? filters['q'].delete_prefix('#').to_i : -1
  end

  def verifier
    Rails.application.message_verifier('reconciliation-library')
  end

  def fingerprint
    Digest::SHA256.hexdigest([Current.tenant_id, filters.sort.to_h].to_json)
  end
end
