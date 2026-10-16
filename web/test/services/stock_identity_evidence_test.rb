# frozen_string_literal: true

require 'test_helper'

class StockIdentityEvidenceTest < ActiveSupport::TestCase
  test 'GTIN check digit leading zeros and empty values' do
    assert_equal StockIdentityEvidence.gtin('012345678905'), StockIdentityEvidence.gtin('0012345678905')
    assert_nil StockIdentityEvidence.gtin('012345678906')
    assert_nil StockIdentityEvidence.gtin('000000000000')
    assert_nil StockIdentityEvidence.gtin('')
    assert_nil StockIdentityEvidence.gtin('SKU-123')
    assert_empty StockIdentityEvidence.aliases(nil, 'CaseSensitive') & StockIdentityEvidence.aliases(nil, 'casesensitive')
  end

  test 'explicit packages normalize decimal grams counts and comma separated milligrams' do
    assert_equal evidence('Calming Tea 7.00 Grams').key, evidence('Tea Calming 7g').key
    assert_equal evidence('Calming Tea (15ct)').key, evidence('Calming Tea 15 Count').key
    assert_equal evidence('Calming Oil 3,500mg').key, evidence('Calming Oil 3500MG').key
    refute_equal evidence('Calming Tea 1g 5 Pack').key, evidence('Calming Tea 5g').key
    refute_equal evidence('Calming Tea 1:2 7g').key, evidence('Calming Tea 2:1 7g').key
    assert_nil evidence('Resin 7g').key
    assert_nil evidence('Calming Tea').key
    assert_nil evidence('Calming Tea 0g').key
  end

  private

  def evidence(text) = StockIdentityEvidence.new(text)
end
