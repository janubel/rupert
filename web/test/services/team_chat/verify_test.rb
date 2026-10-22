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

  EVIDENCE = '{"gross_sales_dollars":"$1,250.00","orders":14,"hours":102.5,"staff":7,"top_product":"Tea 50g","sources":["shopify"]}'

  setup { @prompts = [] }

  def verify(draft, *replies)
    chats = replies.dup
    factory = ->(_instructions) { FakeChat.new(chats, @prompts) }
    TeamChat::Verify.new(config: nil, question: 'How did last week go?', evidence: [EVIDENCE], draft: draft, chat_factory: factory).call
  end

  def checks(*rows) = { 'checks' => rows.each_with_index.map { |(verdict, quote), index| { 'id' => index + 1, 'verdict' => verdict, 'evidence_quote' => quote.to_s } } }
  def fixes(*replacements) = { 'fixes' => replacements.each_with_index.map { |text, index| { 'id' => index + 1, 'replacement' => text } } }

  test 'splits an answer into sentences and list items without markdown, skipping fragments' do
    text = "September went well. Gross sales were **$1,250.00**.\n- 14 orders in [Sales](/sales).\n- Top: Tea 50g\nThanks!"
    assert_equal ['September went well.', 'Gross sales were $1,250.00.', '14 orders in Sales.', 'Top: Tea 50g'],
      TeamChat::Verify.sentences(text)
  end

  test 'dates, times and years are not figures' do
    assert_equal %w[14 3], TeamChat::Verify.figures('On Oct 15–21, 2026 (2026-10-15 at 9:30 am) we had 14 orders in Q3, 3 late.')
  end

  test 'an answer the data supports is kept as it is, with no fix pass' do
    draft = "The team worked 102.5 hours last week (October 15–21, 2026), 7 staff.\n\nGross sales were $1,250.00 from 14 orders."
    outcome = verify(draft, checks(['supported'], ['supported']))

    assert_equal draft, outcome.text
    assert_equal 'original', outcome.kept
    assert_not outcome.fixed
    assert_empty outcome.failed
    assert_equal 1, @prompts.size, 'only the check ran'
    assert_match(/\ADATA:\n.*TASK: CHECK.*^1\. The team worked/m, @prompts.first)
    assert_not_includes @prompts.first, 'How did last week go', 'the checker sees sentences and data, not the conversation'
  end

  test 'a number the data does not have fails, and only that sentence is replaced' do
    draft = "The team worked 102.5 hours last week.\n\nGross sales were $1,250.00. There were 12 orders."
    outcome = verify(draft, checks(['supported'], ['supported'], ['supported']), fixes('There were 14 orders.'))

    assert_equal "The team worked 102.5 hours last week.\n\nGross sales were $1,250.00. There were 14 orders.", outcome.text
    assert_equal 'fixed', outcome.kept
    assert_equal ['12 is not in the data'], outcome.failed.map(&:reason)
    assert_includes @prompts.last, "WRONG SENTENCES:\n1. There were 12 orders. (12 is not in the data)"
    assert_equal draft, outcome.meta['draft']
    assert outcome.meta['failed'].first['fixed']
  end

  test 'a money figure that is not in the data fails even when the checker calls it supported' do
    outcome = verify('Gross sales were $1,520.00 last week.', checks(['supported']), fixes('Gross sales were $1,250.00 last week.'))

    assert_equal '$1,520.00 is not in the data', outcome.failed.first.reason
    assert_equal 'Gross sales were $1,250.00 last week.', outcome.text
  end

  test 'a replacement with a figure the data does not have is not used' do
    draft = 'Gross sales were $1,250.00. There were 12 orders.'
    outcome = verify(draft, checks(['supported'], ['supported']), fixes('There were 13 orders.'))

    assert_equal draft, outcome.text
    assert outcome.fixed, 'a fix was tried'
    assert_equal 'original', outcome.kept
  end

  test 'an empty replacement removes the sentence, and a list item with it' do
    draft = "Last week:\n- Gross sales were $1,250.00.\n- There were 12 orders in total.\n- Top product: Tea 50g."
    outcome = verify(draft, checks(['no_fact'], ['supported'], ['supported'], ['supported']), fixes(''))

    assert_equal "Last week:\n- Gross sales were $1,250.00.\n- Top product: Tea 50g.", outcome.text
  end

  test 'a contradiction counts only with a quote that is really in the data' do
    real = verify('All sales came from Square last week.', checks(['contradicted', '"sources":["shopify"]']), fixes('All sales came from Shopify last week.'))
    assert_equal 'All sales came from Shopify last week.', real.text

    @prompts.clear
    invented = verify('All sales came from Shopify last week.', checks(['contradicted', 'sales came mostly from square stores']))
    assert_empty invented.failed
    assert_equal 1, @prompts.size
  end

  test 'a sentence whose numbers are all in the data passes even when the checker cannot find it' do
    outcome = verify('There were 14 orders, mostly online.', checks(['not_found']))

    assert_empty outcome.failed
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
