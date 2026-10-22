# frozen_string_literal: true

require 'test_helper'

class TeamChatVerifyTest < ActiveSupport::TestCase
  # A stand-in for RubyLLM chats: each ask returns the next scripted reply and records the prompt.
  class FakeChat
    Reply = Struct.new(:content)

    def initialize(replies, log) = (@replies, @log = replies, log)

    def with_schema(_schema) = self

    def ask(prompt)
      @log << prompt
      reply = @replies.shift
      raise reply if reply.is_a?(Exception)

      Reply.new(reply)
    end
  end

  EVIDENCE = '{"gross_sales_dollars":"$1,250.00","orders":14,"top_product":"Tea 50g","period":"2026-09"}'

  setup { @prompts = [] }

  def verify(draft, *replies)
    chats = replies.dup
    factory = ->(_instructions) { FakeChat.new(chats, @prompts) }
    TeamChat::Verify.new(config: nil, question: 'How did September go?', evidence: [EVIDENCE], draft: draft, chat_factory: factory).call
  end

  def checks(*rows) = { 'checks' => rows.each_with_index.map { |(verdict, quote), index| { 'id' => index + 1, 'verdict' => verdict, 'evidence_quote' => quote.to_s } } }

  test 'splits an answer into sentences and list items without markdown, skipping fragments' do
    text = "September went well. Gross sales were **$1,250.00**.\n- 14 orders in [Sales](/sales).\n- Top: Tea 50g\nThanks!"
    assert_equal ['September went well.', 'Gross sales were $1,250.00.', '14 orders in Sales.', 'Top: Tea 50g'],
      TeamChat::Verify.sentences(text)
  end

  test 'an answer the data supports is kept as it is, with no fix pass' do
    draft = 'Gross sales were $1,250.00 in September. There were 14 orders.'
    outcome = verify(draft, checks(['supported', 'gross_sales_dollars $1,250.00'], ['supported', 'orders 14']))

    assert_equal draft, outcome.text
    assert_equal 'original', outcome.kept
    assert_not outcome.fixed
    assert_empty outcome.failed
    assert_equal 1, @prompts.size, 'only the check ran'
    assert_match(/\ADATA:\n.*SENTENCES:\n1\. Gross sales/m, @prompts.first)
    assert_not_includes @prompts.first, 'How did September go', 'the checker sees sentences and data, not the conversation'
  end

  test 'a sentence the data contradicts is fixed, and the fix is kept when it keeps the right figures' do
    draft = 'Gross sales were $1,250.00 in September. There were 12 orders.'
    fixed = 'Gross sales were $1,250.00 in September. There were 14 orders.'
    outcome = verify(draft, checks(['supported', '$1,250.00'], ['contradicted', 'orders 14']), fixed)

    assert_equal fixed, outcome.text
    assert_equal 'fixed', outcome.kept
    assert_equal ['There were 12 orders.'], outcome.failed.map(&:text)
    assert_includes @prompts.last, "WRONG:\n- \"There were 12 orders.\" (the data says otherwise"
    assert_equal 'fixed', outcome.meta['kept']
    assert_equal draft, outcome.meta['draft']
  end

  test 'a fix that drops a figure that was right is not kept' do
    draft = 'Gross sales were $1,250.00 in September. There were 12 orders.'
    outcome = verify(draft, checks(['supported', '$1,250.00'], ['contradicted', 'orders 14']), 'There were 14 orders.')

    assert_equal draft, outcome.text
    assert outcome.fixed, 'a fix was tried'
    assert_equal 'original', outcome.kept
  end

  test 'a fix that adds a figure the data does not have is not kept' do
    draft = 'Gross sales were $1,250.00 in September. There were 12 orders.'
    outcome = verify(draft, checks(['supported', '$1,250.00'], ['contradicted', 'orders 14']),
      'Gross sales were $1,250.00 in September, up $300.00. There were 14 orders.')

    assert_equal draft, outcome.text
  end

  test 'a figure "supported" by a quote that is not in the data fails' do
    outcome = verify('There were 14 orders, mostly online.', checks(['supported', 'online orders were 14 this month']), 'There were 14 orders.')

    assert_equal 'the quoted evidence is not in the data', outcome.failed.first.reason
  end

  test 'a money figure that is not in the data fails even when the checker calls it supported' do
    outcome = verify('Gross sales were $1,520.00.', checks(['supported', '$1,250.00']), 'Gross sales were $1,250.00.')

    assert_equal '$1,520.00 is not in the data', outcome.failed.first.reason
    assert_equal 'Gross sales were $1,250.00.', outcome.text
  end

  test 'a sentence without figures that the data does not mention is left alone' do
    outcome = verify('Things look steady overall.', checks(['not_found', '']))

    assert_empty outcome.failed
    assert_equal 1, @prompts.size
  end

  test 'nothing is checked without tool data, and a failing model leaves the draft' do
    outcome = TeamChat::Verify.new(config: nil, question: 'q', evidence: [], draft: 'There were 14 orders.', chat_factory: ->(_) { raise 'unused' }).call
    assert_empty outcome.claims

    outcome = verify('There were 14 orders.', RuntimeError.new('gateway down'))
    assert_equal 'There were 14 orders.', outcome.text
    assert_equal 'original', outcome.kept
  end

  test 'RUPERT_VERIFY turns the check on for every local bot or for the named ones' do
    qwen = TeamChat::LocalAgents::Agent.new(handle: 'qwen-4b', name: 'Qwen 4B', model: 'qwen3.5-4b')
    { nil => false, '' => false, '0' => false, '1' => true, 'all' => true, 'qwen-4b,qwen-2b' => true, 'liquid' => false }.each do |setting, expected|
      previous = ENV['RUPERT_VERIFY']
      ENV['RUPERT_VERIFY'] = setting
      assert_equal expected, TeamChat::Verify.enabled_for?(qwen), setting.inspect
    ensure
      ENV['RUPERT_VERIFY'] = previous
    end
    assert_not TeamChat::Verify.enabled_for?(nil)
  end
end
