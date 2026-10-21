# frozen_string_literal: true

# FTS5 trigram indexes for substring search on the largest tables: orders,
# customers, and Shopify variants.
class AddTrigramSearchIndexes < ActiveRecord::Migration[8.1]
  INDEXES = {
    'orders' => [['order_number'], ['source_order_id']],
    'customers' => [['email'], ['phone'], ['first_name'], ['last_name']],
    'ShopifyVariant' => [['sku'], ['title']]
  }.freeze

  def up
    create_sqlite_search_indexes
  end

  def down
    drop_sqlite_search_indexes
  end

  private

  def create_sqlite_search_indexes
    INDEXES.each do |table, columns|
      index = sqlite_index_name(table)
      quoted_table = quote_table_name(table)
      quoted_columns = columns.flatten.map { |column| quote_column_name(column) }
      column_list = quoted_columns.join(', ')
      new_values = columns.flatten.map { |column| "new.#{quote_column_name(column)}" }.join(', ')
      old_values = columns.flatten.map { |column| "old.#{quote_column_name(column)}" }.join(', ')
      prefix = "#{index}_sync"

      row_key = table == 'ShopifyVariant' ? 'rowid' : 'id'
      execute "CREATE VIRTUAL TABLE #{index} USING fts5(#{column_list}, tokenize='trigram', content='#{table}', content_rowid='#{row_key}')"
      execute "INSERT INTO #{index}(rowid, #{column_list}) SELECT #{row_key}, #{column_list} FROM #{quoted_table}"
      execute <<~SQL
        CREATE TRIGGER #{prefix}_insert AFTER INSERT ON #{quoted_table} BEGIN
          INSERT INTO #{index}(rowid, #{column_list}) VALUES (new.#{row_key}, #{new_values});
        END
      SQL
      execute <<~SQL
        CREATE TRIGGER #{prefix}_update AFTER UPDATE ON #{quoted_table} BEGIN
          INSERT INTO #{index}(#{index}, rowid, #{column_list}) VALUES ('delete', old.#{row_key}, #{old_values});
          INSERT INTO #{index}(rowid, #{column_list}) VALUES (new.#{row_key}, #{new_values});
        END
      SQL
      execute <<~SQL
        CREATE TRIGGER #{prefix}_delete AFTER DELETE ON #{quoted_table} BEGIN
          INSERT INTO #{index}(#{index}, rowid, #{column_list}) VALUES ('delete', old.#{row_key}, #{old_values});
        END
      SQL
    end
  end

  def drop_sqlite_search_indexes
    INDEXES.each do |table, _columns|
      index = sqlite_index_name(table)
      prefix = "#{index}_sync"
      %w[insert update delete].each { |operation| execute "DROP TRIGGER IF EXISTS #{prefix}_#{operation}" }
      execute "DROP TABLE IF EXISTS #{index}"
    end
  end

  def sqlite_index_name(table)
    "rupert_#{table.downcase}_fts"
  end
end
