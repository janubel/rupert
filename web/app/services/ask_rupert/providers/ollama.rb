# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module AskRupert
  module Providers
    # A local model served by Ollama on this server or its network (Gemma 4 is the
    # baseline being evaluated). The address and model name are instance
    # configuration (OLLAMA_URL, ASK_RUPERT_LOCAL_MODEL), so nothing a workspace
    # administrator types can point the server somewhere else. Streams tokens.
    class Ollama
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 90
      MAX_TOKENS = 700

      def initialize(config = Config.current)
        @config = config
      end

      def name = 'ollama'
      def cloud? = false
      def configured? = @config.local_configured?
      def model = @config.local_model

      def complete(system:, messages:)
        raise ProviderError.new('local model is not configured', kind: :unavailable) unless configured?

        uri = URI.join(@config.local_url.to_s.end_with?('/') ? @config.local_url : "#{@config.local_url}/", 'api/chat')
        request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
        request.body = JSON.generate(model: model, stream: true, options: { temperature: 0.2, num_predict: MAX_TOKENS },
          messages: [{ role: 'system', content: system }] + messages.map { |message| { role: message[:role] == 'assistant' ? 'assistant' : 'user', content: message[:content] } })
        text = +''
        final = {}
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(request) do |response|
            raise ProviderError.new("ollama answered #{response.code}", kind: response.code.to_i == 429 ? :rate_limited : :unavailable) unless response.is_a?(Net::HTTPSuccess)

            buffer = +''
            response.read_body do |chunk|
              buffer << chunk
              while (line = buffer.slice!(/\A[^\n]*\n/))
                piece = parse(line)
                next unless piece

                text << piece.dig('message', 'content').to_s
                yield text if block_given?
                final = piece if piece['done']
              end
            end
          end
        end
        raise ProviderError.new('ollama returned no text', kind: :error) if text.strip.empty?

        Reply.new(text: text.strip, tokens_in: final['prompt_eval_count'].to_i, tokens_out: final['eval_count'].to_i, provider: name, model: model)
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise ProviderError.new('ollama timed out', kind: :timeout)
      rescue SystemCallError, SocketError, IOError, URI::InvalidURIError
        raise ProviderError.new('ollama unreachable', kind: :unavailable)
      end

      private

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
