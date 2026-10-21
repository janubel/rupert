# frozen_string_literal: true

# SQLite contains search: FTS5 trigram indexes for longer queries and a
# case-insensitive LIKE fallback for short queries or schema-loaded DBs.
module SearchSql
  module_function

  SQLITE_FTS = {
    'rupert_orders_fts' => ['orders', %w[order_number source_order_id], 'id'],
    'rupert_customers_fts' => ['customers', %w[email phone first_name last_name], 'id'],
    'rupert_shopifyvariant_fts' => ['ShopifyVariant', %w[sku title], 'rowid']
  }.freeze

  def match(scope, model:, fts_table:, columns:, term:, row_key: 'id')
    if term.length >= 3 && table_exists?(fts_table)
      ensure_fts_ready!(fts_table)
      connection = ActiveRecord::Base.connection
      table = connection.quote_table_name(model.table_name)
      index = connection.quote_table_name(fts_table)
      phrase = %Q("#{term.gsub('"', '""')}")
      scope.where("#{table}.#{row_key} IN (SELECT rowid FROM #{index} WHERE #{index} MATCH ?)", phrase)
    else
      pattern = "%#{term}%"
      scope.where(contains_any(columns), *Array.new(columns.length, pattern))
    end
  end

  def contains_any(columns)
    columns.map { |column| "#{column} LIKE ? COLLATE NOCASE" }.join(' OR ')
  end

  def table_exists?(name)
    connection = ActiveRecord::Base.connection
    connection.select_value(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = #{connection.quote(name)} LIMIT 1"
    ).present?
  rescue ActiveRecord::StatementInvalid
    false
  end

  # schema.rb preserves SQLite virtual tables but not their triggers. Test
  # worker databases and production instances created from the schema dump can
  # therefore start with an empty external-content index. Repair it on the
  # first search, before returning any FTS results.
  def ensure_fts_ready!(index)
    definition = SQLITE_FTS[index]
    return unless definition

    table_name, columns, row_key = definition
    connection = ActiveRecord::Base.connection
    prefix = "#{index}_sync"
    triggers = %w[insert update delete].map { |operation| "#{prefix}_#{operation}" }
    quoted_table = connection.quote_table_name(table_name)
    columns_sql = columns.map { |column| connection.quote_column_name(column) }.join(', ')
    new_values = columns.map { |column| "new.#{connection.quote_column_name(column)}" }.join(', ')
    old_values = columns.map { |column| "old.#{connection.quote_column_name(column)}" }.join(', ')
    rowid = row_key == 'rowid' ? 'rowid' : connection.quote_column_name(row_key)

    present = connection.select_values(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name IN (#{triggers.map { |name| connection.quote(name) }.join(', ')})"
    )
    return if present.size == triggers.size

    connection.execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS #{prefix}_insert AFTER INSERT ON #{quoted_table} BEGIN
        INSERT INTO #{index}(rowid, #{columns_sql}) VALUES (new.#{rowid}, #{new_values});
      END
    SQL
    connection.execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS #{prefix}_update AFTER UPDATE ON #{quoted_table} BEGIN
        INSERT INTO #{index}(#{index}, rowid, #{columns_sql}) VALUES ('delete', old.#{rowid}, #{old_values});
        INSERT INTO #{index}(rowid, #{columns_sql}) VALUES (new.#{rowid}, #{new_values});
      END
    SQL
    connection.execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS #{prefix}_delete AFTER DELETE ON #{quoted_table} BEGIN
        INSERT INTO #{index}(#{index}, rowid, #{columns_sql}) VALUES ('delete', old.#{rowid}, #{old_values});
      END
    SQL
    connection.execute("INSERT INTO #{index}(#{index}) VALUES ('rebuild')")
  end
end
