# frozen_string_literal: true

module TeamChat
  # Only complete, explicit page-navigation requests qualify. Page keys and aliases
  # come from the permission-aware guide; fuzzy matches and mixed requests use the agent.
  class NavigationAnswer
    ENGINE = 'direct_navigation'
    VERSION = 1
    class Unavailable < StandardError; end

    PREFIX = /\A(?:where (?:is|are)|where['’]s|where (?:can|do) i (?:find|open|see|access)|how (?:can|do) i (?:open|find|access|get to|navigate to)|open|go to|take me to|navigate to)\s+(?:the\s+|my\s+)?(.+?)\s*[?!.]?\z/i
    # The guide's other search keywords (for example time, new, in, out) are
    # intentionally too broad to count as exact page names.
    EXACT_ALIASES = (%w[home overview stock products items staff pto vacation todo] + ['to do']).freeze
    TARGET = /\A[[:alpha:]][[:alnum:] &'’_-]{0,70}\z/

    def self.query(text)
      text = text.to_s.strip
      return if text.length > 160 || text.match?(/[\r\n]/)

      text = text.sub(/\A@rupert\b[:,]?\s*/i, '').sub(/\Aplease\s+/i, '')
      found = PREFIX.match(text)
      return unless found

      target = found[1].sub(/\s+(?:page|screen)\z/i, '').strip
      normalize(target) if TARGET.match?(target)
    end

    def self.normalize(text) = text.to_s.downcase.tr('_-', '  ').squish

    def initialize(execution, telemetry:)
      @execution, @telemetry = execution, telemetry
    end

    def call(started:)
      @execution.check!
      run = @execution.run
      saved = run.configuration
      recovering = saved['engine'] == ENGINE
      return false unless recovering || (saved.empty? && run.transcript.empty? && run.tool_results.empty? && run.steps.zero?)
      trigger = Message.find_by(id: run.request_context['trigger_id'], tenant_id: run.tenant_id)
      model_requested = run.message.meta.to_h.values_at('agent', 'battery', 'compare_of').any?(&:present?)
      return false if !recovering && (model_requested || run.message.parent_id || trigger&.attachment_infos&.exists?)

      query = self.class.query(run.request_context['last_chat'])
      if recovering
        raise Unavailable, 'Unsupported navigation checkpoint' unless saved['navigation_version'] == VERSION && saved['query'] == query && query.present?
      else
        return false unless query

        page = unique_page(query)
        return false unless page

        @execution.locked do
          @execution.private_delivery!
          run.update!(configuration: { 'engine' => ENGINE, 'model' => nil, 'endpoint' => nil,
            'navigation_version' => VERSION, 'query' => query, 'page_key' => page.key })
          @telemetry.record('routing', outcome: 'succeeded', facts: { 'route' => ENGINE, 'version' => VERSION })
        end
        saved = run.configuration
      end

      result = @telemetry.measure('tool', facts: { 'name' => 'where_is', 'route' => ENGINE }) do
        @execution.check!
        user = fresh_user
        # Re-resolve the pinned page on every claim; no saved URL or answer is replayed.
        page = AskRupert::Guide.new(user).permitted_pages.find { |candidate| candidate.key == saved['page_key'] }
        raise Unavailable, 'Navigation destination no longer available' unless page

        lookup = AskRupert::Tools.new(user: user).call('where_is', { 'query' => page.title })
        link = Array(lookup.links).find { |item| item[:kind] == 'page' && item[:path] == page.path }
        raise Unavailable, 'Navigation destination could not be verified' unless lookup.ok && link && Links.real?(link[:path])

        link
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      title = result[:title].to_s.gsub(/[\[\]\\]/) { |char| "\\#{char}" }
      meta = run.message.meta.to_h.merge('engine' => ENGINE, 'model' => nil, 'tokens_in' => nil, 'tokens_out' => nil,
        'tools' => ['where_is'], 'duration_ms' => ms, 'outcome' => 'ok', 'inference' => 'not_applicable')
      @execution.write_reply!({ body: "Open [#{title}](#{result[:path]}).", status: 'done', activity: nil, meta: meta }, terminal: 'succeeded')
      true
    end

    private

    def fresh_user
      User.find_by!(id: @execution.run.request_context['requester_id'], tenant_id: @execution.run.tenant_id)
    end

    def unique_page(query)
      pages = AskRupert::Guide.new(fresh_user).permitted_pages.select do |page|
        synonyms = AskRupert::Guide::SYNONYMS.fetch(page.key, '').split.select { |word| EXACT_ALIASES.include?(self.class.normalize(word)) }
        aliases = [page.title, page.key.tr('_', ' '), page.key.tr('_', ' ').singularize, *synonyms]
        aliases.any? { |name| self.class.normalize(name) == query }
      end
      pages.one? ? pages.first : nil
    end
  end
end
