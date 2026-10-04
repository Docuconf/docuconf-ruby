# frozen_string_literal: true

require "json"

module Docuconf
  module Anyway
    # JSON Schemas for config files and json variables (SPEC §4.6: "schemas
    # come from code").
    #
    # A schema is written as a Ruby type spec, so the platform checks a file
    # against the same shape the app reads:
    #
    #   S = Docuconf::Anyway::Schema
    #   {
    #     routes: S.array({match: S.string(pattern: "^/"), upstream: String, "timeout?": String}, min_items: 1)
    #   }
    #
    # - String, Integer, Float (or Numeric), :boolean and Object (anything)
    #   are leaf types; a Hash is an object with exactly those keys (a key
    #   ending in "?" is optional); [spec] is an array of spec.
    # - S.string / S.integer / S.number / S.array / S.enum / S.map /
    #   S.nullable add constraints.
    # - Anything responding to #json_schema or #to_json_schema (for example a
    #   dry-schema with its :json_schema extension) is used as is.
    #
    # An explicit JSON Schema can be given instead with `json_schema:`. The
    # boot-time validator supports the keywords in SUPPORTED; anything else
    # is rejected at declaration time rather than silently ignored.
    module Schema
      # A JSON Schema fragment built by the helpers below.
      class Node
        attr_reader :schema

        def initialize(schema)
          @schema = schema
        end
      end

      SUPPORTED = %w[
        $schema $id title description default examples $comment format deprecated readOnly writeOnly
        type enum const properties required additionalProperties items minItems maxItems uniqueItems
        minimum maximum exclusiveMinimum exclusiveMaximum multipleOf minLength maxLength pattern
        minProperties maxProperties anyOf oneOf allOf not
      ].freeze
      TYPES = %w[object array string integer number boolean null].freeze

      module_function

      def string(min_length: nil, max_length: nil, pattern: nil, enum: nil, format: nil)
        Node.new(compact("type" => "string", "minLength" => min_length, "maxLength" => max_length,
          "pattern" => pattern, "enum" => enum, "format" => format))
      end

      def integer(min: nil, max: nil)
        Node.new(compact("type" => "integer", "minimum" => min, "maximum" => max))
      end

      def number(min: nil, max: nil)
        Node.new(compact("type" => "number", "minimum" => min, "maximum" => max))
      end

      def boolean = Node.new("type" => "boolean")

      def any = Node.new({})

      def array(of, min_items: nil, max_items: nil)
        Node.new(compact("type" => "array", "items" => to_json_schema(of), "minItems" => min_items,
          "maxItems" => max_items))
      end

      def enum(*values) = Node.new("enum" => values.flatten.map { |v| v.is_a?(Symbol) ? v.to_s : v })

      # An object with arbitrary keys whose values all match `of`.
      def map(of) = Node.new("type" => "object", "additionalProperties" => to_json_schema(of))

      def nullable(spec) = Node.new("anyOf" => [to_json_schema(spec), {"type" => "null"}])

      # An object; `additional: true` allows keys beyond those listed.
      def object(props, additional: false)
        s = to_json_schema(props)
        s["additionalProperties"] = true if additional
        Node.new(s)
      end

      # Converts a type spec to a JSON Schema (a Hash with String keys).
      def to_json_schema(spec)
        case spec
        when Node then deep_stringify(spec.schema)
        when Hash then object_schema(spec)
        when Array
          raise ArgumentError, "an array type spec holds exactly one element type: [String]" unless spec.size == 1

          {"type" => "array", "items" => to_json_schema(spec.first)}
        when :boolean, TrueClass, FalseClass then {"type" => "boolean"}
        when :string then {"type" => "string"}
        when :integer then {"type" => "integer"}
        when :float, :number then {"type" => "number"}
        when :any then {}
        when Class then class_schema(spec)
        else
          return deep_stringify(spec.json_schema) if spec.respond_to?(:json_schema)
          return deep_stringify(spec.to_json_schema) if spec.respond_to?(:to_json_schema)

          raise ArgumentError, "cannot derive a JSON Schema from #{spec.inspect}"
        end
      end

      def class_schema(klass)
        if klass <= String || klass <= Symbol then {"type" => "string"}
        elsif klass <= Integer then {"type" => "integer"}
        elsif klass <= Numeric then {"type" => "number"}
        elsif klass == TrueClass || klass == FalseClass then {"type" => "boolean"}
        elsif klass == Object || klass == BasicObject then {}
        elsif klass == Hash then {"type" => "object"}
        elsif klass == Array then {"type" => "array"}
        elsif klass.respond_to?(:json_schema) then deep_stringify(klass.json_schema)
        elsif klass.respond_to?(:to_json_schema) then deep_stringify(klass.to_json_schema)
        else
          raise ArgumentError, "cannot derive a JSON Schema from #{klass}; use a Hash spec or json_schema:"
        end
      end

      def object_schema(hash)
        props = {}
        required = []
        hash.each do |k, v|
          key = k.to_s
          if key.end_with?("?")
            key = key.chomp("?")
          else
            required << key
          end
          props[key] = to_json_schema(v)
        end
        out = {"type" => "object", "properties" => props}
        out["required"] = required unless required.empty?
        out["additionalProperties"] = false
        out
      end

      def compact(h) = h.compact

      def deep_stringify(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        when Symbol then obj.to_s
        else obj
        end
      end

      # Problems with a schema that the boot validator could not enforce:
      # unknown keywords ($ref, patternProperties, ...) and non-RE2 patterns.
      def problems(schema, path = "")
        out = []
        unless schema.is_a?(Hash)
          return schema == true || schema == false ? [] : ["#{path.empty? ? "/" : path}: a schema must be an object"]
        end

        schema.each do |k, v|
          here = "#{path}/#{k}"
          unless SUPPORTED.include?(k)
            out << "#{here}: keyword #{k} is not supported by the docuconf validator"
            next
          end
          case k
          when "properties"
            v.each { |pk, ps| out.concat(problems(ps, "#{here}/#{pk}")) }
          when "items", "not"
            out.concat(problems(v, here))
          when "additionalProperties"
            out.concat(problems(v, here)) if v.is_a?(Hash)
          when "anyOf", "oneOf", "allOf"
            v.each_with_index { |s, i| out.concat(problems(s, "#{here}/#{i}")) }
          when "pattern"
            if (p = RE2.problem(v))
              out << "#{here}: #{p}"
            end
          when "type"
            Array(v).each { |t| out << "#{here}: unknown type #{t}" unless TYPES.include?(t) }
          end
        end
        out
      end

      # Validates data (parsed JSON or YAML) against a schema. Returns a list
      # of "path: message" strings, empty when valid.
      def validate(schema, data, path = "")
        return [] if schema == true || schema.nil? || (schema.is_a?(Hash) && schema.empty?)
        return ["#{at(path)}: no value is allowed here"] if schema == false

        errors = []
        if schema.key?("type")
          types = Array(schema["type"])
          unless types.any? { |t| type_matches?(t, data) }
            return ["#{at(path)}: expected #{types.join(" or ")}, got #{json_type(data)}"]
          end
        end
        if schema.key?("enum") && schema["enum"].none? { |e| json_equal?(e, data) }
          errors << "#{at(path)}: must be one of #{schema["enum"].map(&:to_json).join(", ")}"
        end
        if schema.key?("const") && !json_equal?(schema["const"], data)
          errors << "#{at(path)}: must equal #{schema["const"].to_json}"
        end

        case data
        when Hash then errors.concat(validate_object(schema, data, path))
        when Array then errors.concat(validate_array(schema, data, path))
        when String then errors.concat(validate_string(schema, data, path))
        when Numeric then errors.concat(validate_number(schema, data, path))
        end

        Array(schema["allOf"]).each { |s| errors.concat(validate(s, data, path)) }
        if schema.key?("anyOf") && schema["anyOf"].none? { |s| validate(s, data, path).empty? }
          errors << "#{at(path)}: matches none of the allowed shapes (anyOf)"
        end
        if schema.key?("oneOf")
          n = schema["oneOf"].count { |s| validate(s, data, path).empty? }
          errors << "#{at(path)}: must match exactly one shape (oneOf), matches #{n}" unless n == 1
        end
        if schema.key?("not") && validate(schema["not"], data, path).empty?
          errors << "#{at(path)}: matches a disallowed shape (not)"
        end
        errors
      end

      def validate_object(schema, data, path)
        errors = []
        data = data.transform_keys(&:to_s)
        Array(schema["required"]).each do |k|
          errors << "#{at(path)}: missing required property #{k}" unless data.key?(k)
        end
        props = schema["properties"] || {}
        data.each do |k, v|
          if props.key?(k)
            errors.concat(validate(props[k], v, "#{path}/#{k}"))
          elsif schema.key?("additionalProperties")
            ap = schema["additionalProperties"]
            if ap == false
              errors << "#{at(path)}: property #{k} is not allowed"
            elsif ap.is_a?(Hash)
              errors.concat(validate(ap, v, "#{path}/#{k}"))
            end
          end
        end
        if schema["minProperties"] && data.size < schema["minProperties"]
          errors << "#{at(path)}: needs at least #{schema["minProperties"]} properties"
        end
        if schema["maxProperties"] && data.size > schema["maxProperties"]
          errors << "#{at(path)}: allows at most #{schema["maxProperties"]} properties"
        end
        errors
      end

      def validate_array(schema, data, path)
        errors = []
        if schema["minItems"] && data.size < schema["minItems"]
          errors << "#{at(path)}: needs at least #{schema["minItems"]} items, has #{data.size}"
        end
        if schema["maxItems"] && data.size > schema["maxItems"]
          errors << "#{at(path)}: allows at most #{schema["maxItems"]} items, has #{data.size}"
        end
        errors << "#{at(path)}: items must be unique" if schema["uniqueItems"] && data.uniq.size != data.size
        if schema["items"].is_a?(Hash) || [true, false].include?(schema["items"])
          data.each_with_index { |v, i| errors.concat(validate(schema["items"], v, "#{path}/#{i}")) }
        end
        errors
      end

      def validate_string(schema, data, path)
        errors = []
        len = data.length
        errors << "#{at(path)}: shorter than #{schema["minLength"]} characters" if schema["minLength"] && len < schema["minLength"]
        errors << "#{at(path)}: longer than #{schema["maxLength"]} characters" if schema["maxLength"] && len > schema["maxLength"]
        if schema["pattern"] && !RE2.compile(schema["pattern"]).match?(data)
          errors << "#{at(path)}: does not match pattern #{schema["pattern"]}"
        end
        errors
      end

      def validate_number(schema, data, path)
        errors = []
        errors << "#{at(path)}: below minimum #{schema["minimum"]}" if schema["minimum"] && data < schema["minimum"]
        errors << "#{at(path)}: above maximum #{schema["maximum"]}" if schema["maximum"] && data > schema["maximum"]
        if schema["exclusiveMinimum"].is_a?(Numeric) && data <= schema["exclusiveMinimum"]
          errors << "#{at(path)}: must be above #{schema["exclusiveMinimum"]}"
        end
        if schema["exclusiveMaximum"].is_a?(Numeric) && data >= schema["exclusiveMaximum"]
          errors << "#{at(path)}: must be below #{schema["exclusiveMaximum"]}"
        end
        if schema["multipleOf"] && !(data.to_r % schema["multipleOf"].to_r).zero?
          errors << "#{at(path)}: not a multiple of #{schema["multipleOf"]}"
        end
        errors
      end

      def type_matches?(type, data)
        case type
        when "object" then data.is_a?(Hash)
        when "array" then data.is_a?(Array)
        when "string" then data.is_a?(String) || data.is_a?(Symbol)
        when "integer" then data.is_a?(Integer) || (data.is_a?(Float) && data.finite? && data == data.floor)
        when "number" then data.is_a?(Numeric) && !(data.is_a?(Float) && !data.finite?)
        when "boolean" then data == true || data == false
        when "null" then data.nil?
        else false
        end
      end

      def json_type(data)
        case data
        when Hash then "object"
        when Array then "array"
        when String, Symbol then "string"
        when Integer then "integer"
        when Numeric then "number"
        when true, false then "boolean"
        when nil then "null"
        else data.class.name
        end
      end

      def json_equal?(a, b)
        return a == b if a.is_a?(Numeric) && b.is_a?(Numeric)

        deep_stringify(a) == deep_stringify(b)
      end

      def at(path) = path.empty? ? "/" : path
    end
  end
end
