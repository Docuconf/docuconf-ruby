# frozen_string_literal: true

require "json"

module Docuconf
  module Anyway
    # Contract-first mode (SPEC §11.2 item 11): validates an environment
    # against a contract given as data (the contract exported as JSON, e.g.
    # with `cue export`), with no Anyway::Config declaration, and returns the
    # typed values.
    #
    #   contract = Docuconf::Anyway::Contract.parse(File.read("contract.json"))
    #   values = contract.load(ENV) # => {"PORT" => 8080, "TIMEOUT" => 30.seconds, ...}
    #
    # It reads every wire encoding of SPEC §5 (csv, json and indexed lists;
    # go, iso8601, seconds and timespan durations), with the same parsing and
    # constraint checks as the declaration path. Problems with the
    # environment raise ValidationError listing all of them; a malformed
    # contract raises DeclarationError. File inputs and overlays are not
    # checked in this mode.
    class Contract
      LIST_ENCODINGS = %w[csv json indexed].freeze
      DURATION_ENCODINGS = %w[go iso8601 seconds timespan].freeze

      attr_reader :vars, :profiles

      # Accepts the contract as JSON text or as a Hash.
      def self.parse(contract)
        data = contract.is_a?(String) ? JSON.parse(contract) : Schema.deep_stringify(contract)
        new(data)
      rescue JSON::ParserError => e
        raise DeclarationError, ["contract is not valid JSON: #{e.message}"]
      end

      def initialize(data)
        problems = []
        problems << "contract must be an object" unless data.is_a?(Hash)
        data = {} unless data.is_a?(Hash)
        problems << "apiVersion must be #{API_VERSION}" unless data["apiVersion"] == API_VERSION
        problems << "kind must be ConfigContract" unless data["kind"] == "ConfigContract"
        vars = data["vars"] || {}
        problems << "vars must be an object" unless vars.is_a?(Hash)
        @vars = vars.is_a?(Hash) ? vars.sort.filter_map { |name, h| build_var(name, h, problems) } : []
        @profiles = data["profiles"]
        check_profiles(problems) if @profiles
        raise DeclarationError, problems unless problems.empty?
      end

      def var(name) = vars.find { |v| v.name == name }

      # Validates `env` (a Hash of String to String; the process environment
      # by default) and returns the typed values by variable name: nil for an
      # absent optional variable, durations as Duration.build makes them
      # (ActiveSupport::Duration when loaded, else seconds).
      #
      # With termination_log: true (the default), a failure is also written
      # where Kubernetes reports it, as at boot.
      def load(env = ENV, termination_log: true)
        values, violations = evaluate(env)
        unless violations.empty?
          error = ValidationError.new(violations)
          Docuconf::Anyway.write_termination_log(error.message) if termination_log
          raise error
        end
        values.to_h { |name, v| [name, v && var(name).type == "duration" ? Duration.build(v) : v] }
      end

      # Returns [contract values by name, violations] without raising.
      # Durations are Integer nanoseconds.
      def evaluate(env = ENV)
        env = env.to_h
        violations = []
        found = {}
        vars.each do |var|
          raw = raw_value(var, env)
          value, failure = Values.from_env(var, raw)
          if failure
            violations << violation(var, failure)
            found[var.name] = :failed
            next
          end
          next if value.equal?(Values::UNSET)

          failures = Values.check(var, value)
          if failures.empty?
            found[var.name] = value
          else
            failures.each { |f| violations << violation(var, f) }
            found[var.name] = :failed
          end
        end

        profile = selected_profile(found)
        values = {}
        vars.each do |var|
          next if found[var.name] == :failed

          value = found.fetch(var.name) { fallback(var, profile) }
          if value.nil? && var.required
            violations << Violation.new(input: var.name, kind: :var, code: :missing_required, message: "required, and not set")
          end
          values[var.name] = value
        end
        [values, violations]
      end

      private

      def violation(var, failure)
        Violation.new(input: var.name, kind: :var, code: failure.code, message: failure.message)
      end

      # The raw environment input of a variable: its value, or for an
      # indexed list the values of NAME__0, NAME__1, ... (nil when there are
      # none).
      def raw_value(var, env)
        return env[var.name] unless var.type == "list" && var.encoding == "indexed"

        items = []
        items << env["#{var.name}__#{items.size}"] while env.key?("#{var.name}__#{items.size}")
        items.empty? ? nil : items
      end

      # The default when a variable is unset: the selected profile's, then
      # the variable's own.
      def fallback(var, profile)
        defaults = profile ? (@profiles.dig("defaults", profile) || {}) : {}
        raw = defaults.key?(var.name) ? defaults[var.name] : var.default
        return nil if raw.nil?

        value, = Values.from_typed(var, raw)
        value
      end

      def selected_profile(found)
        return nil unless @profiles

        selector = var(@profiles["selector"])
        value = found[selector.name] unless found[selector.name] == :failed
        value = selector.default if value.nil?
        (value || @profiles["default"]).to_s
      end

      def check_profiles(problems)
        unless @profiles.is_a?(Hash) && var(@profiles["selector"].to_s)
          problems << "profiles.selector must name a declared variable"
          @profiles = nil
          return
        end
        (@profiles["defaults"] || {}).each do |profile, values|
          values.each do |name, raw|
            v = var(name)
            if v.nil?
              problems << "profiles.defaults.#{profile}.#{name} is not a declared variable"
              next
            end
            cv, failure = Values.from_typed(v, raw)
            failures = failure ? [failure] : Values.check(v, cv)
            failures.each { |f| problems << "profiles.defaults.#{profile}.#{name}: #{f.message}" }
          end
        end
      end

      CONSTRAINTS = {
        "min" => :min, "max" => :max, "minLength" => :min_length, "maxLength" => :max_length,
        "pattern" => :pattern, "values" => :values, "schemes" => :schemes, "minItems" => :min_items,
        "maxItems" => :max_items, "itemMin" => :item_min, "itemMax" => :item_max, "schema" => :schema
      }.freeze
      private_constant :CONSTRAINTS

      def build_var(name, h, problems)
        label = name.to_s
        unless h.is_a?(Hash)
          problems << "#{label}: must be an object"
          return nil
        end
        problems << "#{label}: is not a valid environment variable name" unless ENV_NAME_RE.match?(label)
        type = h["type"].to_s
        unless VAR_TYPES.include?(type)
          problems << "#{label}: unknown type #{h["type"].inspect}"
          return nil
        end

        constraints = CONSTRAINTS.each_with_object({}) { |(k, sym), c| c[sym] = h[k] unless h[k].nil? }
        items = nil
        encoding = nil
        case type
        when "list"
          items = h["items"].to_s
          problems << "#{label}: items must be string or int" unless %w[string int].include?(items)
          encoding = (h["encoding"] || "csv").to_s
          problems << "#{label}: unknown list encoding #{encoding.inspect}" unless LIST_ENCODINGS.include?(encoding)
          Declaration.check_item_bounds(type, items, constraints, problems, label,
            names: {item_min: "itemMin", item_max: "itemMax"})
        when "duration"
          encoding = (h["encoding"] || "go").to_s
          problems << "#{label}: unknown duration encoding #{encoding.inspect}" unless DURATION_ENCODINGS.include?(encoding)
          %i[min max].each do |k|
            next unless constraints[k]

            ns = Duration.parse_go(constraints[k].to_s)
            if ns.nil? || ns.negative?
              problems << "#{label}: #{k} #{constraints[k].inspect} is not a duration"
              constraints.delete(k)
            end
          end
        when "enum"
          problems << "#{label}: enum needs a non-empty values list" if Array(constraints[:values]).empty?
        end
        regexp = nil
        if constraints[:pattern]
          begin
            regexp = RE2.compile(constraints[:pattern].to_s)
          rescue RE2::Unsupported => e
            problems << "#{label}: pattern is not RE2: #{e.message}"
          end
        end
        if constraints[:schema]
          Schema.problems(constraints[:schema]).each { |p| problems << "#{label}: schema #{p}" }
        end

        var = VarDecl.new(
          attr: label.to_sym, name: label, type: type, description: h["description"].to_s,
          secret: h["secret"] == true, required: h["required"] == true, default: h["default"],
          constraints: constraints, items: items, regexp: regexp, encoding: encoding,
          separator: h["separator"]&.to_s
        )
        problems << "#{label}: separator must not be empty" if var.separator.empty?
        unless var.default.nil?
          cv, failure = Values.from_typed(var, var.default)
          failures = failure ? [failure] : Values.check(var, cv)
          failures.each { |f| problems << "#{label}: default #{f.message}" }
        end
        var
      end
    end

    # Validates `env` against a contract (JSON text or a Hash) and returns
    # the typed values. See Contract.
    def self.load_contract(contract, env: ENV, termination_log: true)
      Contract.parse(contract).load(env, termination_log: termination_log)
    end
  end
end
