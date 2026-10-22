# frozen_string_literal: true

module Mcp
  module Tools
    class AiHealth < Tool
      tool 'ai_health',
        title: 'AI integration health',
        description: "Health of Rupert's opencode integration (Ask Rupert and team chat): whether the API key is valid, the " \
                     'live list of free models, whether the agent\'s model is still offered, tokens in and out today and ' \
                     'over 7 days, rate-limit hits and warnings. Same data as the System page card. Counts and ' \
                     'classifications only — never the key or any message content. opencode has no balance or usage ' \
                     'API, so token counts are the agent\'s own logged runs. Instance operators only. Read-only.',
        scope: 'system:read'

      # Instance diagnostics: only an instance operator's token sees the tool,
      # like the System page it mirrors.
      def self.available_to?(token)
        super && token.user.super_admin?
      end

      def call(_args)
        unless user.super_admin?
          raise ToolError.new('AI health is for the instance operator. Ask a platform administrator.', kind: 'denied')
        end

        data = AiHealthSnapshot.build
        today = data[:tokens][:today]
        text = "opencode integration: #{data[:state]}. Key #{data[:key][:state]}; #{data[:free_models][:count]} free models; " \
               "model #{data[:model][:id]} #{data[:model][:state]}. Tokens today #{today[:tokens_in]} in / #{today[:tokens_out]} out " \
               "(#{data[:tokens][:week_total]} over 7 days). Rate-limit hits in 24 h: " \
               "#{data[:rate_limits][:runs_24h] + data[:rate_limits][:checks_24h]}." \
               "#{" Warnings: #{data[:warnings].map { |w| w[:message] }.join(' ')}" if data[:warnings].any?}"
        result(text, data)
      end
    end
  end
end
