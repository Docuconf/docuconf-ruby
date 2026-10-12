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
    # It reads every wire encoding of SPEC §5 (csv, json and indexed lists
    # and key sets; go, iso8601, seconds and timespan durations), with the
    # same parsing and constraint checks as the declaration path. File
    # inputs (SPEC §4.6) are read and checked as at boot, from under
    # DOCUCONF_FILE_ROOT when it is set. Profiles and overlays (SPEC §4.4,
    # §4.7) are layered as a host with config files layers them: the
    # variable's default, then the selected profile's default, then an
    # overlay, then the environment. Problems raise ValidationError listing
    # all of them; a malformed contract raises DeclarationError.
    class Contract
      LIST_ENCODINGS = %w[csv json indexed].freeze
      DURATION_ENCODINGS = %w[go iso8601 seconds timespan].freeze
      OVERLAY_FORMATS = %w[json yaml toml].freeze

      # An overlay of a contract (SPEC §4.7).
      ContractOverlay = Struct.new(:name, :format, :path, :key_separator, :reload, keyword_init: true)

      attr_reader :vars, :files, :overlays, :profiles

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
        files = data["files"] || {}
        problems << "files must be an object" unless files.is_a?(Hash)
        @files = files.is_a?(Hash) ? files.sort.filter_map { |name, h| build_file(name, h, problems) } : []
        Declaration.check_files(nil, @files, @vars, problems)
        @files.each do |f|
          pv = f[:password_var]
          next unless pv

          v = var(pv)
          problems << "file #{f.name}: passwordVar #{pv} must name a declared secret variable" unless v&.secret
        end
        overlays = data["overlays"] || {}
        problems << "overlays must be an object" unless overlays.is_a?(Hash)
        @overlays = overlays.is_a?(Hash) ? overlays.sort.filter_map { |name, h| build_overlay(name, h, problems) } : []
        @profiles = data["profiles"]
        check_profiles(problems) if @profiles
        raise DeclarationError, problems unless problems.empty?
      end

      def var(name) = vars.find { |v| v.name == name }

      def file(name) = files.find { |f| f.name == name }

      # Validates `env` (a Hash of String to String; the process environment
      # by default) and returns the typed values by variable name: nil for an
      # absent optional variable, durations as Duration.build makes them
      # (ActiveSupport::Duration when loaded, else seconds), and key sets as
      # KeySet. File inputs are included by name: a config file's data, a
      # text file's text, a TLSMaterial, CABundle, OpenSSL::PKCS12 or a
      # binary file's path, and nil for an absent optional file.
      #
      # With termination_log: true (the default), a failure is also written
      # where Kubernetes reports it, as at boot.
      #
      # Inputs the contract declares reload: watch (files and overlays) are
      # reloaded as in the declaration path: a background thread polls them
      # every DOCUCONF_WATCH_INTERVAL seconds and, when one changes and
      # passes its checks again, replaces its entry in the returned Hash
      # (for an overlay, every variable's) and calls the hooks registered
      # with Loaded#on_change / #on_overlay_change. A change that fails is
      # logged and the previous value kept. The environment is read once,
      # here: a reload reuses it, keystore passwords included. watch: false
      # (or Docuconf::Anyway.watch_files = false) loads once and starts no
      # thread; Loaded#reload_status still reports generation 1.
      def load(env = ENV, termination_log: true, watch: Docuconf::Anyway.watch_files)
        env = env.to_h.freeze
        values, violations = evaluate(env)
        unless violations.empty?
          error = ValidationError.new(violations)
          Docuconf::Anyway.write_termination_log(error.message) if termination_log
          raise error
        end
        out = Loaded.new
        store(out, values)
        out.secret_names = vars.select(&:secret).map(&:name) + files.select(&:secret).map(&:name)
        start_watching(out, env, watch)
        out
      end

      # Writes evaluated values into a Loaded, as the app receives them.
      def store(out, values)
        values.each do |name, v|
          decl = var(name)
          out[name] = decl && !v.nil? ? Values.host_value(decl, v) : v
        end
        out
      end

      # The values Contract#load returns: a Hash whose #inspect and pp show
      # secret values as [FILTERED]. Entries for reload: watch inputs are
      # replaced in place when the input changes, so read them on every use.
      class Loaded < Hash
        attr_writer :secret_names
        attr_accessor :reloads, :watcher

        def inspect = filtered.inspect
        alias_method :to_s, :inspect

        def pretty_print(q) = q.pp(filtered)

        # Calls the block with the new value after the watched file input
        # `name` changes, passes its checks and replaces the old value; never
        # for a rejected change. Returns a Subscription.
        def on_change(name, &block)
          name = name.to_s
          unless reloads&.watched?(name)
            raise ArgumentError, "#{name} is not a file input declared reload: watch"
          end

          reloads.subscribe(name, block)
        end

        # Calls the block with these values after a watched overlay changes
        # and the contract, evaluated again, passes. Returns a Subscription.
        def on_overlay_change(&block)
          raise ArgumentError, "the contract declares no overlay with reload: watch" unless reloads&.keys&.any? { |k| k.start_with?("overlay:") }

          reloads.subscribe(:overlays, block)
        end

        # The ReloadStatus of a watched input (a file by name, an overlay as
        # "overlay:<name>"), or with no argument every watched input's.
        def reload_status(name = nil)
          return(reloads ? reloads.all : {}) if name.nil?
          raise ArgumentError, "#{name} is not a watched input (reload: watch)" unless reloads

          reloads.status(name.to_s)
        end

        # Stops the background reload thread, if any.
        def stop_watching
          watcher&.stop
          self
        end

        private

        def filtered
          names = @secret_names || []
          {}.merge(self).to_h { |k, v| [k, names.include?(k) && !v.nil? ? "[FILTERED]" : v] }
        end
      end

      # Returns [contract values by name, violations] without raising.
      # Durations are Integer nanoseconds, key sets Arrays of keys; file
      # inputs are included by name.
      def evaluate(env = ENV, now: Time.now)
        env = env.to_h
        root = env["DOCUCONF_FILE_ROOT"]
        root = nil if root&.empty?
        violations = []
        profile = selected_profile(env)
        layers = overlay_layers(env, root, violations)
        found = {}
        vars.each do |var|
          raw = raw_value(var, env)
          layer = layers[var.name]
          source = nil
          if raw.nil? || (raw.is_a?(String) && raw.empty? && var.type != "string") || (raw.is_a?(Array) && raw.empty?)
            raw = nil
            if layer
              next found[var.name] = :failed if layer[:bad]

              source = " (from overlay #{layer[:overlay]})"
            end
          elsif layer && !layer[:bad]
            Docuconf::Anyway.warn("#{var.name} is set in the environment and in overlay #{layer[:overlay]}; " \
              "the environment wins")
          end

          if raw.nil? && layer && !layer[:bad]
            value, failure = layer[:items] ? Values.parse_items(var, layer[:items]) : Values.parse_wire(var, layer[:raw])
          else
            value, failure = raw.is_a?(Values::Failure) ? [nil, raw] : Values.from_env(var, raw)
          end
          if failure
            violations << violation(var, failure, source)
            found[var.name] = :failed
            next
          end
          next if value.equal?(Values::UNSET)

          Docuconf::Anyway.warn(Validator.deprecated_message(var.name, var.deprecated)) if var.deprecated
          failures = Values.check(var, value)
          if failures.empty?
            found[var.name] = value
          else
            failures.each { |f| violations << violation(var, f, source) }
            found[var.name] = :failed
          end
        end

        values = {}
        vars.each do |var|
          next if found[var.name] == :failed

          value = found.fetch(var.name) { fallback(var, profile) }
          if value.nil? && var.required
            violations << Violation.new(input: var.name, kind: :var, code: :missing_required, message: "required, and not set")
          end
          values[var.name] = value
        end

        files.each do |f|
          value, failures = Files.load(f, env: env, password: keystore_password(f, env), now: now)
          failures.each { |x| violations << Violation.new(input: f.name, kind: :file, code: x.code, message: x.message) }
          if f.deprecated && failures.empty? && !value.nil?
            Docuconf::Anyway.warn(Validator.deprecated_message("file #{f.name}", f.deprecated))
          end
          values[f.name] = value
        end
        [values, violations]
      end

      private

      def start_watching(out, env, watch)
        watched_files = files.select { |f| f.reload == "watch" }
        watched_overlays = overlays.select { |o| o.reload == "watch" }
        return if watched_files.empty? && watched_overlays.empty?

        out.reloads = Reloads.new(watched_files.map(&:name) + watched_overlays.map { |o| "overlay:#{o.name}" })
        return unless watch

        interval = Float(env.fetch("DOCUCONF_WATCH_INTERVAL", Watcher::DEFAULT_INTERVAL))
        passwords = watched_files.to_h { |f| [f.accessor, keystore_password(f, env)] }
        out.watcher = ContractWatcher.new(self, out, watched_files, overlays: watched_overlays, env: env,
          interval: interval, passwords: passwords).start
      end

      def violation(var, failure, source = nil)
        Violation.new(input: var.name, kind: :var, code: failure.code, message: "#{failure.message}#{source}")
      end

      # The keystore password: its variable's raw value, or the empty
      # password when the variable is unset (SPEC §11.2 item 7).
      def keystore_password(file, env)
        pv = file[:password_var]
        return nil unless file.type == "keystore"
        return "" unless pv

        env[pv].to_s
      end

      # The raw environment input of a variable: its value, or for an
      # indexed list the values of NAME__0, NAME__1, ... (nil when there are
      # none). The list is present when any NAME__<n> is set, and its items
      # must run from 0 with no gap (SPEC §5); a gap is a Values::Failure.
      # Only decimal suffixes with no leading zero are items, so nested keys
      # such as NAME__HOST are ignored.
      def raw_value(var, env)
        return env[var.name] unless %w[list keySet].include?(var.type) && var.encoding == "indexed"

        prefix = "#{var.name}__"
        count = env.each_key.filter_map { |k| k.delete_prefix(prefix)[INDEX_RE] if k.start_with?(prefix) }
          .map { |s| s.to_i + 1 }.max
        return nil unless count

        items = []
        count.times do |i|
          unless env.key?("#{prefix}#{i}")
            return Values::Failure.new(:invalid_type,
              "items must be numbered from #{prefix}0 with no gap, but #{prefix}#{i} is not set")
          end
          items << env["#{prefix}#{i}"]
        end
        items
      end

      INDEX_RE = /\A(?:0|[1-9][0-9]*)\z/
      private_constant :INDEX_RE

      # The default when a variable is unset: the selected profile's, then
      # the variable's own.
      def fallback(var, profile)
        defaults = profile ? (@profiles.dig("defaults", profile) || {}) : {}
        raw = defaults.key?(var.name) ? defaults[var.name] : var.default
        return nil if raw.nil?

        value, = Values.from_typed(var, raw)
        value
      end

      # The profile in effect (SPEC §4.4): the selector's value when the
      # environment sets it (for a string selector the empty string is a
      # value, naming a profile with no file), else profiles.default.
      def selected_profile(env)
        return nil unless @profiles

        selector = var(@profiles["selector"])
        raw = env[selector.name]
        return raw if raw && (!raw.empty? || selector.type == "string")

        @profiles["default"].to_s
      end

      # Reads every overlay (SPEC §4.7), in name order, and returns each
      # variable's value from the first overlay that sets it:
      # {name => {overlay:, raw: or items:}}, or {bad: true} once a bad
      # value has been reported. Problems with an overlay file itself are
      # file_malformed or file_unreadable for the overlay.
      def overlay_layers(env, root, violations)
        layers = {}
        selector = @profiles && @profiles["selector"]
        overlays.each do |o|
          path = root && o.path.start_with?("/") ? File.join(root, o.path) : o.path
          data, failure = Overlays.parse_file(path, o.format)
          if failure
            violations << Violation.new(input: o.name, kind: :overlay, code: failure.code, message: failure.message)
            next
          end
          next if data.nil?

          vars.each do |v|
            next if v.config_key.nil? || v.name == selector

            found, value = Overlays.dig(data, v.config_key.split(o.key_separator, -1))
            next if !found || value.nil? # null is unset
            if layers.key?(v.name)
              Docuconf::Anyway.warn("#{v.name} is set in overlays #{layers[v.name][:overlay]} and #{o.name}; the first wins")
              next
            end

            where = "overlay #{o.name}, at #{v.config_key}"
            if v.secret
              # Never print it: it is secret material in a ConfigMap.
              violations << Violation.new(input: v.name, kind: :var, code: :invalid_type,
                message: "is secret, but #{where} sets it; supply secrets through the environment")
              layers[v.name] = {overlay: o.name, bad: true}
              next
            end
            layer, msg = Overlays.wire_value(v, value)
            if msg
              violations << Violation.new(input: v.name, kind: :var, code: :invalid_type, message: "#{where}: #{msg}")
              layers[v.name] = {overlay: o.name, bad: true}
              next
            end
            layers[v.name] = layer.merge(overlay: o.name)
          end
        end
        layers
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
        "maxItems" => :max_items, "itemMin" => :item_min, "itemMax" => :item_max,
        "itemMinLength" => :item_min_length, "itemMaxLength" => :item_max_length, "schema" => :schema,
        "minKeys" => :min_keys, "maxKeys" => :max_keys, "keyMinLength" => :key_min_length,
        "keyMaxLength" => :key_max_length
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
        when "keySet"
          items = "string"
          encoding = (h["encoding"] || "csv").to_s
          problems << "#{label}: unknown key set encoding #{encoding.inspect}" unless LIST_ENCODINGS.include?(encoding)
          problems << "#{label}: a keySet is always secret" unless h["secret"] == true
          Declaration.check_key_set(constraints, problems, label,
            names: {min_keys: "minKeys", max_keys: "maxKeys", key_min_length: "keyMinLength", key_max_length: "keyMaxLength"})
        when "enum"
          problems << "#{label}: enum needs a non-empty values list" if Array(constraints[:values]).empty?
        end
        %i[min_keys max_keys key_min_length key_max_length].each { |k| constraints.delete(k) } unless type == "keySet"
        # The meta-schema allows minLength only on a string, maxLength on a
        # string, url or json, and item lengths only on a string list.
        constraints.delete(:min_length) unless type == "string"
        constraints.delete(:max_length) unless %w[string url json].include?(type)
        Declaration.check_lengths(type, items, constraints, problems, label,
          names: {min_length: "minLength", max_length: "maxLength",
                  item_min_length: "itemMinLength", item_max_length: "itemMaxLength"})
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

        # details are docs only (SPEC §4.2): checked, never read at runtime.
        details = h["details"]&.to_s
        Docs.check(label, details, problems)
        deprecated = contract_deprecated(label, h, problems, kind: :var)
        var = VarDecl.new(
          attr: label.to_sym, name: label, type: type, description: h["description"].to_s, details: details,
          secret: h["secret"] == true, required: h["required"] == true, default: h["default"],
          constraints: constraints, items: items, regexp: regexp, encoding: encoding,
          separator: h["separator"]&.to_s, deprecated: deprecated, config_key: h["configKey"]&.to_s
        )
        problems << "#{label}: separator must not be empty" if var.separator.empty?
        unless var.default.nil?
          cv, failure = Values.from_typed(var, var.default)
          failures = failure ? [failure] : Values.check(var, cv)
          failures.each { |f| problems << "#{label}: default #{f.message}" }
        end
        var
      end

      # A deprecated block (SPEC §4.2), checked: {message:, replaced_by:} or nil.
      def contract_deprecated(label, h, problems, kind:)
        d = h["deprecated"]
        return nil if d.nil?
        unless d.is_a?(Hash)
          problems << "#{label}: deprecated must be an object with a message"
          return nil
        end

        dep = {message: d["message"].to_s, replaced_by: d["replacedBy"]&.to_s}
        Declaration.check_deprecated(label, dep, h["required"] == true, problems, kind: kind)
        dep
      end

      FILE_OPTIONS = {
        "dnsNames" => :dns_names, "keyAlgorithms" => :key_algorithms, "minRemaining" => :min_remaining,
        "requireCA" => :require_ca, "minCertificates" => :min_certificates, "passwordVar" => :password_var,
        "pattern" => :pattern, "minLength" => :min_length, "maxLength" => :max_length, "schema" => :schema,
        "format" => :format
      }.freeze
      private_constant :FILE_OPTIONS

      # A file input (SPEC §4.6) as the declaration path builds it, so both
      # run the same boot checks.
      def build_file(name, h, problems)
        label = "file #{name}"
        unless h.is_a?(Hash)
          problems << "#{label}: must be an object"
          return nil
        end
        type = h["type"].to_s
        unless FILE_TYPES.include?(type)
          problems << "#{label}: unknown file type #{h["type"].inspect}"
          return nil
        end
        options = FILE_OPTIONS.each_with_object({}) { |(k, sym), o| o[sym] = h[k] unless h[k].nil? }
        options[:format] = options[:format].to_s if options[:format]
        if options[:schema]
          Schema.problems(options[:schema]).each { |p| problems << "#{label}: schema #{p}" }
        end
        if options[:min_remaining]
          ns = Duration.parse_go(options[:min_remaining].to_s)
          problems << "#{label}: minRemaining #{options[:min_remaining].inspect} is not a duration" if ns.nil? || ns.negative?
        end
        details = h["details"]&.to_s
        FileDecl.new(
          accessor: name.to_s.to_sym, name: name.to_s, type: type, description: h["description"].to_s,
          details: details, required: h["required"] == true,
          secret: h["secret"] == true || %w[tls keystore].include?(type),
          path: h["path"].to_s, path_env: h["pathEnv"]&.to_s, reload: (h["reload"] || "restart").to_s,
          max_size: h["maxSize"], group: h["group"]&.to_s,
          deprecated: contract_deprecated(label, h, problems, kind: :file), options: options
        )
      end

      def build_overlay(name, h, problems)
        label = "overlay #{name}"
        unless h.is_a?(Hash)
          problems << "#{label}: must be an object"
          return nil
        end
        o = ContractOverlay.new(name: name.to_s, format: h["format"].to_s, path: h["path"].to_s,
          key_separator: h["keySeparator"].to_s, reload: (h["reload"] || "restart").to_s)
        problems << "#{label}: name must be a DNS label" unless INPUT_NAME_RE.match?(o.name)
        problems << "#{label}: format must be json, yaml or toml" unless OVERLAY_FORMATS.include?(o.format)
        if !ABS_PATH_RE.match?(o.path) || o.path.split("/").any? { |p| p == "." || p == ".." } ||
            o.path.include?("//") || o.path.end_with?("/")
          problems << "#{label}: path #{o.path.inspect} must be absolute and normalised"
        end
        problems << "#{label}: keySeparator must be \":\" or \".\"" unless %w[: .].include?(o.key_separator)
        problems << "#{label}: reload must be restart or watch" unless [nil, "restart", "watch"].include?(h["reload"])
        o
      end
    end

    # Validates `env` against a contract (JSON text or a Hash) and returns
    # the typed values. See Contract.
    def self.load_contract(contract, env: ENV, termination_log: true)
      Contract.parse(contract).load(env, termination_log: termination_log)
    end
  end
end
