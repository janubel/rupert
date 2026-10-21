# frozen_string_literal: true

require 'test_helper'

class SearchSqlProbe < ActiveRecord::Base
  self.table_name = 'rupert_search_sql_probes'
end

class SearchSqlTest < ActiveSupport::TestCase
  test 'fallback uses a case-insensitive LIKE' do
    sql = SearchSql.contains_any(%w[sku title])

    assert_includes sql, 'LIKE ? COLLATE NOCASE'
    refute_includes sql, 'ILIKE'
  end

  test 'SQLite FTS5 trigram search finds middle-of-field substrings' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:rupert_search_sql_probes) do |table|
      table.string :value
    end
    connection.execute("CREATE VIRTUAL TABLE rupert_search_sql_probe_fts USING fts5(value, tokenize='trigram')")
    connection.execute("INSERT INTO rupert_search_sql_probes(value) VALUES ('Acalypha wilkesiana red')")
    connection.execute(<<~SQL)
      INSERT INTO rupert_search_sql_probe_fts(rowid, value)
      SELECT id, value FROM rupert_search_sql_probes
    SQL

    matches = SearchSql.match(
      SearchSqlProbe.all, model: SearchSqlProbe,
      fts_table: 'rupert_search_sql_probe_fts', columns: %w[value], term: 'lypha'
    )

    assert_equal ['Acalypha wilkesiana red'], matches.pluck(:value)
  ensure
    connection&.drop_table(:rupert_search_sql_probes, if_exists: true)
    connection&.drop_table(:rupert_search_sql_probe_fts, if_exists: true)
  end
end
