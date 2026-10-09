# frozen_string_literal: true

require "json"
require "uri"

module Docuconf
  module Anyway
    # Parsing and constraint checks shared by boot validation (values from
    # the environment, YAML, credentials or defaults), declaration checks
    # (defaults) and export (profile values).
    #
    # A "contract value" is the typed form the contract uses: Integer for
    # int, Float or Integer for float, true/false, nanoseconds (Integer) for
    # duration, Array for list, parsed JSON for json, String otherwise.
    module Values
      INT_RE = /\A-?(?:0|[1-9][0-9]*)\z/
      FLOAT_RE = /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
      URL_RE = /\A[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s]+\z/
      INT64 = (-(2**63))..((2**63) - 1)
      # anyway_config's :boolean caster treats these as true; everything else
      # is false. docuconf accepts them plus their false counterparts and
      # rejects anything else, rather than silently reading "flase" as false.
      TRUE_RE = /\A(?:true|t|yes|y|1)\z/i
      FALSE_RE = /\A(?:false|f|no|n|0)\z/i

      Failure = Struct.new(:code, :message)

      # Reference prefixes that injectors resolve before the app starts
      # (SPEC §4.5.1): Bank-Vaults (vault:), 1Password (op://) and vals or
      # similar wrappers (ref+).
      INJECTOR_REF_RE = %r{\A(vault:|op://|ref\+)}

      module_function

      # Reads one variable's environment value (SPEC §5): a String, or for
      # an indexed list the Array of its NAME__0, NAME__1, ... values. Returns
      # [contract_value, nil], [nil, Failure], or [UNSET, nil] when the
      # variable counts as unset (absent, or empty for a non-string type).
      def from_env(var, raw)
        return [UNSET, nil] if raw.nil?
        return [UNSET, nil] if raw.is_a?(Array) ? raw.empty? : (raw.empty? && var.type != "string")

        failure = Array(raw).lazy.map { |r| unresolved_reference(var, r) }.find(&:itself)
        return [nil, failure] if failure

        parse_wire(var, raw)
      end

      UNSET = Object.new.freeze

      # Parses an environment string (SPEC §5) in the variable's encoding.
      # Returns [contract_value, nil] or [nil, Failure]. Values are never
      # trimmed.
      def parse_wire(var, raw)
        case var.type
        when "string", "enum" then [raw, nil]
        when "url" then [raw, nil]
        when "int" then parse_int(raw, var)
        when "float" then parse_float(raw, var)
        when "bool"
          return [true, nil] if TRUE_RE.match?(raw)
          return [false, nil] if FALSE_RE.match?(raw)

          [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not a boolean (true or false)")]
        when "duration"
          ns = Duration.parse_wire(raw, var.encoding)
          # A declared variable also reads Go syntax (30s), as its defaults
          # do, so .env files and docker-compose can use either form. The
          # contract still declares iso8601, which is what the platform
          # renders.
          if ns.nil? && var.respond_to?(:lenient_duration) && var.lenient_duration
            ns = Duration.parse_go(raw)
            ns = nil if ns&.negative?
          end
          return [ns, nil] if ns

          expected = Duration.describe_encoding(var.encoding)
          expected += " or a Go duration such as 30s" if var.respond_to?(:lenient_duration) && var.lenient_duration
          [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not #{expected}")]
        when "list" then parse_list(var, raw)
        when "json"
          begin
            parsed = JSON.parse(raw, allow_nan: false)
          rescue JSON::ParserError
            return [nil, Failure.new(:invalid_type, "#{var.secret ? "the value" : "value"} is not valid JSON")]
          end
          # maxLength bounds the value as received, whitespace included,
          # not as it would be re-encoded (SPEC §4.3).
          failure = json_max_length(var, raw)
          failure ? [nil, failure] : [parsed, nil]
        else
          [raw, nil]
        end
      end

      # A list in its encoding: csv (split on the separator, trimming
      # spaces around it as anyway_config's array coercion does), json (an
      # array), or indexed (raw is already the Array of item strings).
      def parse_list(var, raw)
        items =
          case var.encoding
          when "indexed" then Array(raw)
          when "json"
            begin
              parsed = JSON.parse(raw, allow_nan: false)
            rescue JSON::ParserError
              return [nil, Failure.new(:invalid_type, "#{var.secret ? "the value" : "value"} is not a valid JSON array")]
            end
            return [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not a JSON array")] unless parsed.is_a?(Array)

            return parse_json_items(var, parsed)
          else
            raw.split(/\s*#{Regexp.escape(var.separator)}\s*/, -1)
          end
        return [items, nil] unless var.items == "int"

        out = []
        items.each_with_index do |s, i|
          v, failure = parse_int(s, var)
          return [nil, Failure.new(failure.code, "item #{i}: #{failure.message}")] if failure

          out << v
        end
        [out, nil]
      end

      def parse_json_items(var, items)
        items.each_with_index do |x, i|
          ok = var.items == "int" ? x.is_a?(Integer) : x.is_a?(String)
          unless ok
            shown = var.secret ? "" : " #{JSON.generate(x)}"
            return [nil, Failure.new(:invalid_type, "item #{i}#{shown} is not #{var.items == "int" ? "an integer" : "a string"}")]
          end
          if var.items == "int" && !INT64.cover?(x)
            return [nil, Failure.new(:out_of_range, "item #{i}#{var.secret ? "" : " #{x}"} is outside the 64-bit integer range")]
          end
        end
        [items, nil]
      end

      def parse_int(raw, var = nil)
        return [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not an integer")] unless INT_RE.match?(raw)

        i = raw.to_i
        return [nil, Failure.new(:out_of_range, "#{show(var, raw)} is outside the 64-bit integer range")] unless INT64.cover?(i)

        [i, nil]
      end

      def parse_float(raw, var = nil)
        return [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not a number")] unless FLOAT_RE.match?(raw)

        f = Float(raw)
        return [nil, Failure.new(:invalid_type, "#{show(var, raw)} is not a finite number")] unless f.finite?

        [f, nil]
      end

      # A secret still holding an injector reference means the injector did
      # not run (SPEC §11.2). The message names the scheme, never the value.
      # Returns a Failure or nil.
      def unresolved_reference(var, raw)
        return nil unless var.secret && raw.is_a?(String)

        m = INJECTOR_REF_RE.match(raw)
        return nil unless m

        Failure.new(:invalid_type,
          "holds an unresolved #{m[1]} reference; the injector that should resolve it did not run")
      end

      # Converts a typed value (from YAML, credentials, a default or a
      # programmatic override) to a contract value. Strings are parsed as
      # if they came from the environment, since YAML often quotes values.
      def from_typed(var, value)
        return parse_wire(var, value) if value.is_a?(String) && !%w[string enum url duration].include?(var.type)

        bad = -> { [nil, Failure.new(:invalid_type, "#{show(var, value)} is not a #{var.type}")] }
        case var.type
        when "string", "enum"
          value.is_a?(String) || value.is_a?(Symbol) ? [value.to_s, nil] : bad.call
        when "url"
          value.is_a?(String) || value.is_a?(URI::Generic) ? [value.to_s, nil] : bad.call
        when "int"
          return bad.call unless value.is_a?(Integer)
          return [nil, Failure.new(:out_of_range, "#{show(var, value)} is outside the 64-bit integer range")] unless INT64.cover?(value)

          [value, nil]
        when "float"
          value.is_a?(Numeric) && !(value.is_a?(Float) && !value.finite?) ? [value, nil] : bad.call
        when "bool"
          [true, false].include?(value) ? [value, nil] : bad.call
        when "duration"
          ns = Duration.to_ns(value)
          ns.nil? || ns.negative? ? bad.call : [ns, nil]
        when "list"
          return bad.call unless value.is_a?(Array)

          if var.items == "int"
            return bad.call unless value.all? { |x| x.is_a?(Integer) || (x.is_a?(String) && INT_RE.match?(x)) }

            ints = value.map { |x| x.is_a?(Integer) ? x : Integer(x, 10) }
            if (i = ints.index { |x| !INT64.cover?(x) })
              return [nil, Failure.new(:out_of_range, "item #{i}#{var.secret ? "" : " (#{ints[i]})"} is outside the 64-bit integer range")]
            end

            [ints, nil]
          else
            value.all? { |x| x.is_a?(String) || x.is_a?(Symbol) || x.is_a?(Numeric) } ? [value.map(&:to_s), nil] : bad.call
          end
        when "json"
          value = Schema.deep_stringify(value)
          # A structured value (from YAML, an overlay or a default) has no
          # wire string; its compact JSON is what the platform would send.
          return [value, nil] unless var.constraints[:max_length]

          begin
            wire = JSON.generate(value)
          rescue JSON::GeneratorError
            return bad.call
          end
          failure = json_max_length(var, wire)
          failure ? [nil, failure] : [value, nil]
        else
          [value, nil]
        end
      end

      # The length of a value in characters: Unicode code points, never
      # bytes (SPEC §4.3). A binary or US-ASCII string, as the environment
      # is under a C or POSIX locale, is read as UTF-8.
      def char_length(s)
        s = s.dup.force_encoding(Encoding::UTF_8) if s.encoding == Encoding::BINARY || s.encoding == Encoding::US_ASCII
        s.length
      end

      # A json value's wire string against maxLength. Returns a Failure or nil.
      def json_max_length(var, wire)
        max = var.constraints[:max_length]
        return nil unless max

        n = char_length(wire)
        return nil if n <= max

        Failure.new(:out_of_range, "is #{n} characters of JSON, above maxLength #{max}")
      end

      # Checks a contract value against the variable's constraints. Returns
      # a list of Failures.
      def check(var, value)
        out = []
        c = var.constraints
        case var.type
        when "string"
          len = char_length(value)
          if c[:min_length] && len < c[:min_length]
            out << Failure.new(:out_of_range, "#{show(var, value)} is shorter than #{c[:min_length]} characters")
          end
          if c[:max_length] && len > c[:max_length]
            out << Failure.new(:out_of_range, "#{show(var, value)} is longer than #{c[:max_length]} characters")
          end
          if var.regexp && !var.regexp.match?(value)
            out << Failure.new(:pattern_mismatch, "#{show(var, value)} does not match pattern #{c[:pattern]}")
          end
        when "int", "float"
          out << Failure.new(:out_of_range, "#{show(var, value)} is below min #{c[:min]}") if c[:min] && value < c[:min]
          out << Failure.new(:out_of_range, "#{show(var, value)} is above max #{c[:max]}") if c[:max] && value > c[:max]
        when "duration"
          shown = var.secret ? "the value" : Duration.format_go(value)
          if c[:min] && value < Duration.parse_go(c[:min])
            out << Failure.new(:out_of_range, "#{shown} is below min #{c[:min]}")
          end
          if c[:max] && value > Duration.parse_go(c[:max])
            out << Failure.new(:out_of_range, "#{shown} is above max #{c[:max]}")
          end
        when "url"
          if !URL_RE.match?(value)
            out << Failure.new(:invalid_type, "#{show(var, value)} is not a URL with a scheme://")
          elsif c[:schemes] && !c[:schemes].include?(value[/\A[^:]+/])
            scheme = var.secret ? "" : " #{value[/\A[^:]+/]}"
            out << Failure.new(:invalid_scheme, "URL scheme#{scheme} is not one of #{c[:schemes].join(", ")}")
          elsif c[:max_length] && (n = char_length(value)) > c[:max_length]
            out << Failure.new(:out_of_range, "#{show(var, value)} is #{n} characters, above maxLength #{c[:max_length]}")
          end
        when "enum"
          unless c[:values].include?(value)
            out << Failure.new(:not_in_enum, "#{show(var, value)} is not one of #{c[:values].join(", ")}")
          end
        when "list"
          if c[:min_items] && value.size < c[:min_items]
            out << Failure.new(:too_few_items, "has #{value.size} item(s), needs at least #{c[:min_items]}")
          end
          if c[:max_items] && value.size > c[:max_items]
            out << Failure.new(:too_many_items, "has #{value.size} item(s), allows at most #{c[:max_items]}")
          end
          if (lo = c[:item_min]) && (i = value.index { |x| x < lo })
            out << Failure.new(:out_of_range, "item #{i}#{var.secret ? "" : " (#{value[i]})"} is below item_min #{lo}")
          end
          if (hi = c[:item_max]) && (i = value.index { |x| x > hi })
            out << Failure.new(:out_of_range, "item #{i}#{var.secret ? "" : " (#{value[i]})"} is above item_max #{hi}")
          end
          if var.items == "string"
            # Each item after splitting, so a separator is never counted.
            if (lo = c[:item_min_length]) && (i = value.index { |x| char_length(x) < lo })
              out << Failure.new(:out_of_range,
                "item #{i}#{var.secret ? "" : " (#{value[i].inspect})"} is #{char_length(value[i])} characters, below item_min_length #{lo}")
            end
            if (hi = c[:item_max_length]) && (i = value.index { |x| char_length(x) > hi })
              out << Failure.new(:out_of_range,
                "item #{i}#{var.secret ? "" : " (#{value[i].inspect})"} is #{char_length(value[i])} characters, above item_max_length #{hi}")
            end
          end
        when "json"
          if c[:schema]
            errs = Schema.validate(c[:schema], value)
            unless errs.empty?
              detail = var.secret ? "#{errs.size} schema error(s)" : errs.first(5).join("; ")
              out << Failure.new(:schema_mismatch, "does not match its schema: #{detail}")
            end
          end
        end
        out
      end

      # How a value appears in a message: never for a secret.
      def show(var, value)
        return "the value" if var&.secret

        value.inspect
      end
    end
  end
end
