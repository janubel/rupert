# frozen_string_literal: true

require 'json'

module TeamChat
  # Which model answers in team chat, from instance configuration (environment),
  # never from a setting an administrator types, so nobody can point the server
  # at an arbitrary address from the web.
  #
  #   RUPERT_CHAT_PROVIDER  opencode_go | local_gateway | ollama | openai | opencode_cli (default: auto)
  #                         local_gateway = the rupert-llm gateway at RUPERT_LOCAL_LLM_URL (the local @agents' server)
  #   RUPERT_CHAT_MODEL     model id (opencode_go default deepseek-v4.1-flash)
  #   RUPERT_CHAT_API_BASE  base URL for openai (any OpenAI-compatible server) or to override the others
  #   RUPERT_CHAT_API_KEY   key for opencode_go / openai; opencode_go falls back to the key
  #                         `opencode auth login` saved for Ask Rupert (OPENCODE_STATE_DIR)
  #
  # Auto picks OpenCode Go when a key is available, else the local Ollama model
  # (OLLAMA_URL + ASK_RUPERT_LOCAL_MODEL), else the opencode CLI that Ask Rupert
  # already uses (text-only tool protocol, slower but needs nothing new).
  class ModelConfig
    OPENCODE_GO_BASE = 'https://opencode.ai/inference/go/openai/v1'
    DEFAULT_GO_MODEL = 'deepseek-v4.1-flash'
    ENGINES = %w[opencode_go local_gateway ollama openai opencode_cli].freeze
    AUTH_PROVIDERS = %w[opencode-go opencode].freeze

    attr_reader :engine, :model, :api_base

    def self.current = new(ENV)

    # The model for a local @agent, served by the one-model-at-a-time gateway.
    def self.for_local(agent)
      return new(ENV.to_h.merge('RUPERT_CHAT_PROVIDER' => 'opencode_go', 'RUPERT_CHAT_MODEL' => agent.model)) if agent.cloud?

      LocalModel.new(agent)
    end

    # Same interface as ModelConfig, for LocalAgents: no API key, no fallback,
    # long timeouts (a request may wait for another model to unload and this one to load).
    class LocalModel
      attr_reader :agent

      def initialize(agent)
        @agent = agent
      end

      def engine = 'local_gateway'
      def model = agent.model
      def api_base = LocalAgents.base_url
      def native? = true
      def local? = true
      def auto? = false
      def configured? = api_base.present?
      def label = "#{agent.name} on this server"
      def disclosure = "#{agent.name} runs on this server; nothing leaves it."

      def chat(session:, timeout: nil)
        context = RubyLLM.context do |config|
          config.request_timeout = timeout || 600
          config.max_retries = 0
          config.openai_api_base = api_base
          config.openai_api_key = 'local'
          config.openai_use_system_role = true
        end
        context.chat(model: model, provider: :openai, assume_model_exists: true, protocol: :chat_completions)
               .with_headers('x-rupert-session' => session.to_s)
      end
    end

    def initialize(env, auth_file: nil)
      @env = env
      @auth_file = auth_file
      @engine = pick_engine
      @model, @api_base, @api_key = settings_for(@engine)
    end

    # Uses RubyLLM with native tool calling (everything except the opencode CLI).
    def native? = engine != 'opencode_cli'
    def local? = %w[ollama local_gateway].include?(engine)
    def auto? = @env['RUPERT_CHAT_PROVIDER'].blank?

    def configured?
      return true if engine == 'opencode_cli'

      api_base.present? && model.present? && (local? || @api_key.present?)
    end

    def label
      case engine
      when 'opencode_go' then "#{model} through OpenCode Go"
      when 'ollama' then "#{model} on this server (Ollama)"
      when 'local_gateway' then "#{model} on this server"
      when 'openai' then "#{model} at #{URI(api_base).host rescue 'a custom endpoint'}"
      else "#{AskRupert::Providers::Opencode.new.model} through the opencode CLI"
      end
    end

    # Where people's words go, shown under the composer.
    def disclosure
      local? ? 'Rupert answers with a model running on this server; nothing leaves it.' : "Rupert answers with #{label}. What you ask and what he looks up are sent to that service."
    end

    # A RubyLLM chat for one room. The session header lets OpenCode Go group a room's requests.
    def chat(session:, timeout: nil)
      raise ArgumentError, 'opencode_cli does not use RubyLLM' unless native?

      context = RubyLLM.context do |config|
        # A local CPU model may first wait for another model to unload and this one to load.
        config.request_timeout = timeout || (local? ? 600 : 120)
        config.max_retries = timeout ? 0 : (local? ? 0 : 1)
        if engine == 'local_gateway'
          config.openai_api_base = api_base
          config.openai_api_key = 'local'
          config.openai_use_system_role = true
        elsif local?
          config.ollama_api_base = api_base
        else
          config.openai_api_base = api_base
          config.openai_api_key = @api_key
          # OpenAI-compatible gateways (OpenCode Go, DeepSeek, vLLM...) expect 'system', not OpenAI's newer 'developer'.
          config.openai_use_system_role = true
        end
      end
      chat = context.chat(model: model, provider: engine == 'ollama' ? :ollama : :openai, assume_model_exists: true, protocol: :chat_completions)
      engine == 'opencode_go' ? chat.with_headers('x-opencode-session' => session.to_s) : chat
    end

    private

    def pick_engine
      chosen = @env['RUPERT_CHAT_PROVIDER'].to_s.strip
      return chosen if ENGINES.include?(chosen)
      return 'opencode_go' if @env['RUPERT_CHAT_API_KEY'].present? || opencode_key.present?
      return 'ollama' if @env['OLLAMA_URL'].present? && local_model.present?

      'opencode_cli'
    end

    def settings_for(engine)
      case engine
      when 'opencode_go'
        [@env['RUPERT_CHAT_MODEL'].presence || DEFAULT_GO_MODEL, @env['RUPERT_CHAT_API_BASE'].presence || OPENCODE_GO_BASE,
         @env['RUPERT_CHAT_API_KEY'].presence || opencode_key]
      when 'local_gateway'
        [@env['RUPERT_CHAT_MODEL'].presence, @env['RUPERT_LOCAL_LLM_URL'].to_s.strip.chomp('/').presence, nil]
      when 'ollama'
        base = @env['RUPERT_CHAT_API_BASE'].presence || (@env['OLLAMA_URL'].present? ? "#{@env['OLLAMA_URL'].chomp('/')}/v1" : nil)
        [@env['RUPERT_CHAT_MODEL'].presence || local_model, base, nil]
      when 'openai'
        [@env['RUPERT_CHAT_MODEL'].presence, @env['RUPERT_CHAT_API_BASE'].presence, @env['RUPERT_CHAT_API_KEY'].presence]
      else
        [nil, nil, nil]
      end
    end

    def local_model = @env['RUPERT_CHAT_MODEL'].presence || @env['ASK_RUPERT_LOCAL_MODEL'].presence

    # The key `opencode auth login` stored for Ask Rupert's opencode CLI. Read, never logged.
    def opencode_key
      return @opencode_key if defined?(@opencode_key)

      path = @auth_file || File.join(OpencodeCli.state_dir, 'data', 'opencode', 'auth.json')
      data = File.readable?(path) ? JSON.parse(File.read(path)) : {}
      entry = AUTH_PROVIDERS.filter_map { |name| data[name] if data.is_a?(Hash) }.find { |value| value.is_a?(Hash) && value['key'].present? }
      @opencode_key = entry&.dig('key')
    rescue JSON::ParserError, SystemCallError
      @opencode_key = nil
    end
  end
end
