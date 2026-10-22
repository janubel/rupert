# frozen_string_literal: true

module TeamChat
  # A trailing ? in a need permits an explicit null for fields where null is a
  # meaningful unknown/absent state; the key itself must still be present.
  # Executes the ground-truth calls in a battery definition using the asking
  # user's read permissions, then checks declared result paths without printing
  # any business values. This is a contract check, not an LLM run.
  class BatteryCoverage
    COLLECTION_KEYS = %w[rows items lines sales top_products channels queues metrics values].freeze
    Call = Struct.new(:tool, :status, :data, keyword_init: true)
    Question = Struct.new(:item, :calls, :missing_needs, keyword_init: true)
    Report = Struct.new(:questions, keyword_init: true) do
      def errors = questions.sum { |question| question.calls.count { |call| call.status == :error } }
      def missing = questions.sum { |question| question.missing_needs.size }
      def too_many_calls = questions.count { |question| question.item.module == 'cross' && question.calls.size > 2 }
      def passed? = errors.zero? && missing.zero? && too_many_calls.zero?

      def markdown
        lines = ['| Question | Calls | Tool results | Missing needs |', '| --- | ---: | --- | --- |']
        questions.each do |question|
          statuses = question.calls.map { |call| "#{call.tool}: #{call.status}" }.join('<br>').presence || 'no calls'
          missing_text = question.missing_needs.join(', ').presence || '—'
          lines << "| #{question.item.id} | #{question.calls.size} | #{statuses} | #{missing_text} |"
        end
        lines << '' << "Errors: #{errors}. Missing needs: #{missing}. Cross questions over two calls: #{too_many_calls}."
        lines.join("\n")
      end
    end

    def initialize(user:, items:, registry: Mcp::Registry)
      @user = user
      @token = Token.new(user)
      @items = items
      @registry = registry
    end

    def call
      questions = @items.map do |item|
        calls = item.checks.map { |check| run_check(check) }
        missing = item.needs.filter_map do |need|
          tool_name, path = need.to_s.split(':', 2)
          call = calls.find { |candidate| candidate.tool == tool_name }
          need if !call || call.status == :error || !field_present?(call.data, path)
        end
        Question.new(item: item, calls: calls, missing_needs: missing)
      end
      Report.new(questions: questions)
    end

    private

    def run_check(check)
      name = check.is_a?(Hash) ? check['tool'].to_s : check.to_s
      args = (check.is_a?(Hash) ? check['args'].to_h : {}).transform_values { |value| preset_date(value) }
      tool = @registry.find(name)
      return Call.new(tool: name, status: :error) unless tool&.read_only && tool.available_to?(@token)

      outcome = tool.new(token: @token).call(args)
      status = if uncheckable_result?(outcome.data)
        :error
      elsif empty_result?(outcome.data)
        :empty
      else
        :ok
      end
      Call.new(tool: name, status: status, data: outcome.data)
    rescue Mcp::ToolError, StandardError
      # Do not include exception text: it may contain data from the tool result.
      Call.new(tool: name, status: :error)
    end

    def preset_date(value)
      key, edge = value.to_s.match(/\A(\w+)\.(from|to)\z/)&.captures
      preset = TimeRangePicker.preset(key, Date.current) if key
      preset ? preset.public_send(edge).iso8601 : value
    end

    def empty_result?(data)
      return true if data.blank?

      COLLECTION_KEYS.each do |key|
        value = data[key.to_sym] || data[key]
        return value.empty? if value.is_a?(Array)
      end
      false
    end

    def uncheckable_result?(data)
      case data
      when Hash
        title = data[:title] || data['title']
        title.to_s.match?(/\bcould not be checked\z/i) || data.any? { |_, value| uncheckable_result?(value) }
      when Array
        data.any? { |value| uncheckable_result?(value) }
      else
        false
      end
    end

    # A wildcard over an empty array is vacuously present; a non-empty array
    # must contain the requested field on every row, and null values fail.
    def field_present?(data, path)
      return false if path.blank?

      nullable = path.end_with?('?')
      path = path.delete_suffix('?') if nullable
      values = [data]
      empty_wildcard = false
      segments = path.split('.')
      segments.each_with_index do |segment, index|
        wildcard = segment.end_with?('[]')
        key = wildcard ? segment.delete_suffix('[]') : segment
        next_values = []
        values.each do |value|
          symbol_key = key.to_sym
          present = value.is_a?(Hash) && (value.key?(symbol_key) || value.key?(key))
          return false unless present
          child = value.key?(symbol_key) ? value[symbol_key] : value[key]
          return false if child.nil? && !(nullable && index == segments.size - 1 && !wildcard)

          if wildcard
            return false unless child.is_a?(Array)
            empty_wildcard ||= child.empty?
            next_values.concat(child)
          else
            next_values << child
          end
        end
        values = next_values
        return true if values.empty? && empty_wildcard
      end
      nullable || values.any? { |value| !value.nil? }
    end
  end
end
