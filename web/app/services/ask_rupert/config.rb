# frozen_string_literal: true

module AskRupert
  # Per-workspace Ask Rupert settings. Defaults come from here (and ASK_RUPERT_*
  # environment overrides); an administrator's saved values win and are clamped
  # to sane bounds, so a typo cannot disable the limits or open them wide.
  #
  # The local model's address and name are instance configuration (OLLAMA_URL,
  # ASK_RUPERT_LOCAL_MODEL), not a setting, so a workspace administrator cannot
  # point the server at an arbitrary address.
  class Config
    KEY = 'ask_rupert.config'
    MODES = { 'cloud' => 'Cloud model', 'auto' => 'Local model first, cloud as backup',
              'local_only' => 'Local model only (nothing leaves this server)' }.freeze
    BOUNDS = {
      'rate_limit_count' => 1..200, 'rate_limit_window_minutes' => 1..120, 'daily_cap' => 1..2_000,
      'max_message_chars' => 100..4_000, 'context_messages' => 2..30, 'context_chars' => 1_000..20_000,
      'retention_days' => 0..365
    }.freeze
    EDITABLE = (%w[enabled provider_mode] + BOUNDS.keys).freeze

    DEFAULTS = {
      'enabled' => true, 'provider_mode' => 'cloud', 'rate_limit_count' => 20, 'rate_limit_window_minutes' => 10,
      'daily_cap' => 200, 'max_message_chars' => 1_000, 'context_messages' => 12, 'context_chars' => 8_000,
      # Chats are saved until someone clears them. Set a number of days to expire them instead.
      'retention_days' => 0
    }.freeze

    def self.current
      new(stored)
    end

    def self.stored
      raw = Setting.find_by(key: KEY, tenant_id: Current.tenant_id)&.value
      parsed = raw.present? ? JSON.parse(raw) : {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Saves the editable values from a form. Returns the new Config.
    def self.update!(params)
      values = stored.merge(new({}).coerce(params))
      Setting.find_or_create_for(KEY, Current.tenant_id) { |row| row.value = JSON.generate(values) }
      current
    end

    def initialize(values)
      @values = DEFAULTS.merge(env_defaults).merge(coerce(values))
    end

    def [](key) = @values.fetch(key.to_s)
    def enabled? = self['enabled']
    def mode = self['provider_mode']
    def local_only? = mode == 'local_only'
    def to_h = @values.dup

    def local_url = ENV['OLLAMA_URL'].presence
    def local_model = ENV['ASK_RUPERT_LOCAL_MODEL'].presence
    def local_configured? = local_url.present? && local_model.present?

    # Keeps only editable keys, with the right type and inside the bounds.
    def coerce(values)
      return {} unless values.respond_to?(:to_h)

      source = values.to_h.stringify_keys.slice(*EDITABLE)
      source.each_with_object({}) do |(key, value), out|
        case key
        when 'enabled' then out[key] = ActiveModel::Type::Boolean.new.cast(value) ? true : false
        when 'provider_mode' then out[key] = value.to_s if MODES.key?(value.to_s)
        else
          next if value.to_s.strip.empty?

          range = BOUNDS.fetch(key)
          out[key] = Integer(value, exception: false)&.clamp(range.begin, range.end)
        end
      end.compact
    end

    private

    def env_defaults
      { 'rate_limit_count' => ENV['ASK_RUPERT_RATE_LIMIT'], 'daily_cap' => ENV['ASK_RUPERT_DAILY_CAP'],
        'provider_mode' => ENV['ASK_RUPERT_MODE'] }.compact_blank.then { |env| coerce(env) }
    end
  end
end
