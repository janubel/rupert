# frozen_string_literal: true

module Mcp
  module Tools
    # How Rupert stores each kind of business data and which tool answers it.
    class DataGuide < Tool
      tool 'data_guide',
        title: 'Data guide: how Rupert stores data',
        description: 'Explains how Rupert stores a kind of business data (sales, comparisons, tax, refunds and expenses, books ' \
                     'and compliance, staff hours, stock, processing queues, tasks, sync) and which tool answers it, with the ' \
                     'rules that keep figures right (cents, never adding sources or currencies, unknown is not zero). Pass a ' \
                     'topic, or the question you were asked to get the matching topics. Read-only.'

      input_schema(
        type: 'object',
        properties: {
          topic: { type: 'string', enum: ::DataGuide.topics.map(&:key), description: 'One topic.' },
          question: { type: 'string', maxLength: 500, description: 'The question you were asked; returns the topics it is about.' }
        },
        additionalProperties: false
      )

      def call(args)
        list = if args['topic'].present? then [::DataGuide.find(args['topic'])].compact
        elsif args['question'].present? then ::DataGuide.match(args['question'])
        else ::DataGuide.topics
               end
        list = ::DataGuide.topics if list.empty?
        result(::DataGuide.markdown(list),
          { topics: list.map { |topic| { key: topic.key, title: topic.title, tools: topic.tools, guide: topic.card } } })
      end
    end
  end
end
