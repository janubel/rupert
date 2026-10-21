# frozen_string_literal: true

module Mcp
  # Validates tool arguments against the small JSON Schema subset the tools
  # use (object/string/integer/number/boolean/array, enum, length, range,
  # date format, required, additionalProperties: false). Numeric and boolean
  # strings are coerced, because assistants often send "5" or "true".
  # Returns [coerced_arguments, errors].
  class SchemaValidator
    def self.call(schema, arguments)
      new.validate_object(deep_stringify(schema), arguments)
    end

    def self.deep_stringify(value)
      case value
      when Hash then value.to_h { |key, inner| [key.to_s, deep_stringify(inner)] }
      when Array then value.map { |inner| deep_stringify(inner) }
      when Symbol then value.to_s
      else value
      end
    end

    def validate_object(schema, arguments)
      errors = []
      properties = schema['properties'] || {}
      out = {}
      Array(schema['required']).each do |key|
        errors << "#{key} is required." if arguments[key].nil? || (arguments[key].is_a?(String) && arguments[key].strip.empty?)
      end
      arguments.each do |key, value|
        unless properties.key?(key)
          errors << "Unknown argument #{key.to_s.first(60)}. Allowed: #{properties.keys.join(', ').presence || 'none'}." if schema['additionalProperties'] == false
          next
        end
        next if value.nil?

        coerced, problem = check(properties[key], value, key)
        problem ? errors << problem : out[key] = coerced
      end
      [out, errors]
    end

    private

    def check(schema, value, key)
      case schema['type']
      when 'string' then string(schema, value, key)
      when 'integer' then number(schema, value, key, integer: true)
      when 'number' then number(schema, value, key, integer: false)
      when 'boolean' then boolean(value, key)
      when 'array' then array(schema, value, key)
      when 'object' then object(schema, value, key)
      else [value, nil]
      end
    end

    def string(schema, value, key)
      return [nil, "#{key} must be a string."] unless value.is_a?(String)
      return [nil, "#{key} must be one of: #{schema['enum'].join(', ')}."] if schema['enum'] && !schema['enum'].include?(value)
      return [nil, "#{key} must be at most #{schema['maxLength']} characters."] if schema['maxLength'] && value.length > schema['maxLength']
      return [nil, "#{key} must be at least #{schema['minLength']} characters."] if schema['minLength'] && value.strip.length < schema['minLength']
      return [nil, "#{key} must be an ISO date like 2026-10-01."] if schema['format'] == 'date' && !value.strip.match?(/\A\d{4}-\d{2}-\d{2}/)

      [value, nil]
    end

    def number(schema, value, key, integer:)
      value = Integer(value, 10) if integer && value.is_a?(String) && value.strip.match?(/\A-?\d+\z/)
      value = Float(value) if !integer && value.is_a?(String) && value.strip.match?(/\A-?\d+(\.\d+)?\z/)
      value = value.to_i if integer && value.is_a?(Float) && value == value.floor
      valid = integer ? value.is_a?(Integer) : value.is_a?(Numeric)
      return [nil, "#{key} must be #{integer ? 'an integer' : 'a number'}."] unless valid
      return [nil, "#{key} must be at least #{schema['minimum']}."] if schema['minimum'] && value < schema['minimum']
      return [nil, "#{key} must be at most #{schema['maximum']}."] if schema['maximum'] && value > schema['maximum']

      [value, nil]
    end

    def boolean(value, key)
      return [value == 'true', nil] if %w[true false].include?(value)
      return [value, nil] if [true, false].include?(value)

      [nil, "#{key} must be true or false."]
    end

    def array(schema, value, key)
      return [nil, "#{key} must be an array."] unless value.is_a?(Array)
      return [nil, "#{key} may have at most #{schema['maxItems']} items."] if schema['maxItems'] && value.size > schema['maxItems']

      items = schema['items'] || {}
      out = []
      value.each do |item|
        coerced, problem = check(items, item, "#{key} item")
        return [nil, problem] if problem

        out << coerced
      end
      [out, nil]
    end

    def object(schema, value, key)
      return [nil, "#{key} must be an object."] unless value.is_a?(Hash)

      if schema['maxBytes'] && JSON.generate(value).bytesize > schema['maxBytes']
        return [nil, "#{key} must be at most #{schema['maxBytes']} bytes as JSON."]
      end

      [value, nil]
    end
  end
end
