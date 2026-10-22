# frozen_string_literal: true

require 'json'

module AskRupert
  module Providers
    # The opencode CLI (deepseek-v4-flash through
    # the OpenCode API), run with the `chat` agent whose tools are all disabled
    # (see OpencodeCli for the flags): the model can only produce text. Rupert runs
    # the tools itself and feeds the results back.
    #
    # Needs the opencode binary and its `chat` agent on the web/worker host
    # (ASK_RUPERT_OPENCODE_BIN, ASK_RUPERT_OPENCODE_AGENT override the defaults).
    class Opencode
      TIMEOUT = 75
      MAX_PROMPT_CHARS = 30_000
      DEFAULT_MODEL = 'deepseek-v4-flash'
      RATE_LIMIT = /rate.?limit|too many requests|quota|\b429\b|free usage limit/i

      def name = 'opencode'
      def cloud? = true
      def configured? = true
      def model = ENV['OPENCODE_MODEL'].presence || DEFAULT_MODEL
      def binary = ENV['ASK_RUPERT_OPENCODE_BIN'].presence || 'opencode'
      def agent = ENV['ASK_RUPERT_OPENCODE_AGENT'].presence || 'chat'

      def complete(system:, messages:, deadline: nil, checkpoint: nil, &on_text)
        prompt = build_prompt(system, messages)
        stream(prompt, deadline: deadline, checkpoint: checkpoint, &on_text)
      end

      private

      def build_prompt(system, messages)
        transcript = messages.map { |message| "#{message[:role] == 'assistant' ? 'Rupert' : message[:role] == 'tool' ? 'Tool result' : 'Person'}: #{message[:content]}" }
        prompt = [system, '--- Conversation so far ---', *transcript, '--- Your turn ---', 'Reply as Rupert now (a plain-text answer, or one TOOL_CALL line).'].join("\n\n")
        prompt.length > MAX_PROMPT_CHARS ? prompt.last(MAX_PROMPT_CHARS) : prompt
      end

      def stream(prompt, deadline:, checkpoint:)
        text = +''
        tokens = Hash.new(0)
        raw_errors = +''
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pid = nil
        IO.popen(OpencodeCli.env, OpencodeCli.run_command(binary: binary, agent: agent, prompt: prompt), **OpencodeCli.popen_options) do |io|
          pid = io.pid
          lines(io, started: started, deadline: deadline, checkpoint: checkpoint) do |line|
            raise ProviderError.new('opencode timed out', kind: :timeout) if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > TIMEOUT

            event = parse(line)
            if event.nil?
              raw_errors << line.to_s.first(300) if raw_errors.length < 600
              next
            end
            part = event['part']
            if part.is_a?(Hash) && part['type'] == 'text' && part['text'].present?
              text << ' ' unless text.empty?
              text << part['text']
              yield text if block_given?
            elsif event['type'] == 'step_finish'
              add_tokens(tokens, event.dig('part', 'tokens'))
            elsif event['type'] == 'error'
              raw_errors << event['error'].to_json.first(300)
            end
          end
        ensure
          kill(pid) if $!
        end
        raise_empty(raw_errors) if text.strip.empty?
        Reply.new(text: text.strip, tokens_in: tokens[:input] + tokens[:cache_read], tokens_out: tokens[:output] + tokens[:reasoning], provider: name, model: model)
      rescue Errno::ENOENT, Errno::EACCES
        raise ProviderError.new("opencode binary #{binary} not runnable", kind: :unavailable)
      rescue ProviderError
        kill(pid)
        raise
      end

      # A silent child must still obey the deadline and cancellation. each_line
      # alone can wait forever before the first newline arrives.
      def lines(io, started:, deadline:, checkpoint:)
        buffer = +''
        loop do
          checkpoint&.call
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > TIMEOUT || (deadline && Time.current >= deadline)
            raise ProviderError.new('opencode timed out', kind: :timeout)
          end
          next unless IO.select([io], nil, nil, 0.25)

          part = io.read_nonblock(16_384, exception: false)
          break if part.nil?
          next if part == :wait_readable

          buffer << part
          raise ProviderError.new('opencode output too large', kind: :error) if buffer.bytesize > 1_048_576

          while (index = buffer.index("\n"))
            yield buffer.slice!(0..index)
          end
        end
        yield buffer unless buffer.empty?
      end

      def kill(pid)
        Process.kill('TERM', pid) if pid
      rescue Errno::ESRCH
        nil
      end

      def raise_empty(raw_errors)
        kind = raw_errors.match?(RATE_LIMIT) ? :rate_limited : :error
        raise ProviderError.new("opencode returned no text: #{raw_errors.first(200)}", kind: kind)
      end

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def add_tokens(tokens, found)
        return unless found.is_a?(Hash)

        tokens[:input] += found['input'].to_i
        tokens[:output] += found['output'].to_i
        tokens[:reasoning] += found['reasoning'].to_i
        tokens[:cache_read] += found.dig('cache', 'read').to_i if found['cache'].is_a?(Hash)
      end
    end
  end
end
