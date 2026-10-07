# frozen_string_literal: true

module Docuconf
  module Anyway
    ENV_NAME_RE = /\A[A-Z][A-Z0-9_]*\z/
    INPUT_NAME_RE = /\A[a-z](?:[-a-z0-9]{0,40}[a-z0-9])?\z/
    ABS_PATH_RE = /\A\/[A-Za-z0-9._\/-]+\z/
    RESERVED_DIRS = %w[
      / /app /bin /boot /dev /etc /etc/pki /etc/ssl /etc/ssl/certs /home /lib /lib64 /opt /proc /root
      /run /sbin /srv /sys /tmp /usr /usr/lib /usr/local /usr/share /var /var/lib /var/run
    ].freeze
    FEATURE_FLAG_RE = /\A(?:FF|FEATURE|FEATURE_FLAG|ENABLE)_/
    VAR_TYPES = %w[string int float bool duration url enum list json].freeze
    MAX_KEY_DEPTH = 8
    FILE_TYPES = %w[config tls caBundle keystore text binary].freeze
    KEY_ALGORITHMS = %w[RSA ECDSA Ed25519].freeze

    # Options accepted by `describe` and `constrain`.
    VAR_OPTIONS = %i[
      type group examples config_key deprecated secret
      min max min_length max_length pattern values schemes items min_items max_items item_min item_max schema json_schema
    ].freeze

    # One exported variable: an anyway_config attribute and its docuconf
    # metadata.
    class VarDecl
      attr_reader :attr, :name, :type, :description, :secret, :required, :default, :constraints,
        :group, :examples, :config_key, :deprecated, :items, :regexp, :coercion, :lenient_duration

      def initialize(**kw)
        kw.each { |k, v| instance_variable_set(:"@#{k}", v) }
      end

      # The separator of a csv list.
      def separator = @separator || ","

      # The wire encoding (SPEC §5). A declared variable uses the encodings
      # anyway_config parses: iso8601 durations and csv lists. A variable
      # read from a contract (contract-first mode) uses the contract's.
      def encoding
        return @encoding if @encoding

        case type
        when "duration" then "iso8601"
        when "list" then "csv"
        end
      end

      # The variable as contract data (SPEC §4.2), in a stable field order.
      def to_contract
        h = {"type" => type, "description" => description}
        h["required"] = true if required
        h["secret"] = true if secret
        h["group"] = group if group
        h["configKey"] = config_key if config_key
        h["examples"] = examples if examples && !examples.empty?
        if deprecated
          d = {"message" => deprecated[:message]}
          d["replacedBy"] = deprecated[:replaced_by] if deprecated[:replaced_by]
          h["deprecated"] = d
        end
        c = constraints
        case type
        when "string"
          h["minLength"] = c[:min_length] if c[:min_length]
          h["maxLength"] = c[:max_length] if c[:max_length]
          h["pattern"] = c[:pattern] if c[:pattern]
        when "int", "float"
          h["min"] = c[:min] if c[:min]
          h["max"] = c[:max] if c[:max]
        when "duration"
          h["encoding"] = encoding
          h["min"] = c[:min] if c[:min]
          h["max"] = c[:max] if c[:max]
        when "url"
          h["schemes"] = c[:schemes] if c[:schemes]
        when "enum"
          h["values"] = c[:values]
        when "list"
          h["items"] = items
          h["encoding"] = encoding
          h["separator"] = separator
          h["minItems"] = c[:min_items] if c[:min_items]
          h["maxItems"] = c[:max_items] if c[:max_items]
          h["itemMin"] = c[:item_min] if c[:item_min]
          h["itemMax"] = c[:item_max] if c[:item_max]
        when "json"
          h["schema"] = c[:schema] if c[:schema]
        end
        h["default"] = Declaration.contract_default(self, default) unless default.nil?
        h
      end
    end

    # One file input (SPEC §4.6).
    class FileDecl
      attr_reader :accessor, :name, :type, :description, :required, :secret, :path, :path_env, :reload,
        :max_size, :group, :deprecated, :options

      def initialize(**kw)
        kw.each { |k, v| instance_variable_set(:"@#{k}", v) }
      end

      def [](key) = options[key]

      def mount_dir = type == "tls" ? path : File.dirname(path)

      def to_contract(password_env: nil)
        h = {"type" => type}
        h["format"] = options[:format] if %w[config keystore].include?(type)
        h["description"] = description
        h["required"] = true if required
        h["secret"] = true if secret
        h["group"] = group if group
        h["path"] = path
        h["pathEnv"] = path_env if path_env
        h["reload"] = reload if reload != "restart"
        h["maxSize"] = max_size if max_size
        if deprecated
          d = {"message" => deprecated[:message]}
          d["replacedBy"] = deprecated[:replaced_by] if deprecated[:replaced_by]
          h["deprecated"] = d
        end
        o = options
        case type
        when "config"
          h["schema"] = o[:schema] if o[:schema]
        when "tls"
          h["dnsNames"] = o[:dns_names] if o[:dns_names] && !o[:dns_names].empty?
          h["keyAlgorithms"] = o[:key_algorithms] if o[:key_algorithms] && !o[:key_algorithms].empty?
          h["minRemaining"] = o[:min_remaining] if o[:min_remaining]
          h["requireCA"] = true if o[:require_ca]
        when "caBundle"
          h["minCertificates"] = o[:min_certificates] if o[:min_certificates] && o[:min_certificates] != 1
        when "keystore"
          h["passwordVar"] = password_env if password_env
        when "text"
          h["pattern"] = o[:pattern] if o[:pattern]
          h["minLength"] = o[:min_length] if o[:min_length]
          h["maxLength"] = o[:max_length] if o[:max_length]
        end
        h
      end
    end

    # The declaration of one Anyway::Config class: its exported variables
    # and file inputs, after inference and definition-time checks.
    class Declaration
      attr_reader :klass, :vars, :files, :overlays, :nested, :warnings

      def initialize(klass, vars, files, nested, warnings, overlays = [])
        @klass = klass
        @vars = vars
        @files = files
        @overlays = overlays
        @nested = nested
        @warnings = warnings
      end

      def var(attr) = vars.find { |v| v.attr == attr.to_sym }

      def self.contract_default(var, value)
        cv, = Values.from_typed(var, value)
        case var.type
        when "duration" then Duration.format_go(cv)
        else cv
        end
      end

      COERCION_TYPES = {
        string: "string", integer: "int", integer!: "int", float: "float", boolean: "bool",
        uri: "url", duration: "duration", json: "json"
      }.freeze
      TYPE_ALIASES = {
        "integer" => "int", "boolean" => "bool", "uri" => "url", "array" => "list", "number" => "float"
      }.freeze

      # Builds and checks the declaration for an Anyway::Config subclass.
      # Raises DeclarationError listing every problem.
      def self.build(klass)
        problems = []
        warnings = []
        vars = []
        nested = []
        meta = klass.docuconf_var_meta
        excluded = klass.docuconf_excluded
        mapping = klass.coercion_mapping
        defaults = klass.defaults

        (meta.keys - klass.config_attributes).each do |a|
          problems << "#{a}: described but not declared with attr_config"
        end

        klass.config_attributes.each do |attr|
          next if excluded.include?(attr)

          m = meta[attr] || {}
          default = defaults[attr.to_s]
          coercion = mapping[attr]
          env = env_name(klass, attr)

          if (default.is_a?(Hash) || (coercion.is_a?(Hash) && !coercion.key?(:type) && !coercion.key?(:config))) && !m[:type]
            nested << attr
            warnings << "#{klass.name || klass.config_name}.#{attr} is a nested setting; v1alpha1 has no type for it, " \
              "so it stays file-only and the platform cannot set it (exclude it to silence this warning)"
            next
          end

          type, items, err = infer_type(m, coercion, default)
          if err
            problems << "#{env}: #{err}"
            next
          end

          desc = m[:description]
          if desc.nil?
            problems << "#{env}: description is required: describe :#{attr}, \"...\" (or exclude :#{attr} " \
              "if the platform does not set it, e.g. a Rails credential)"
            next
          end
          problems << "#{env}: description must be at least 5 characters" if desc.to_s.strip.length < 5
          problems << "#{env}: is not a valid environment variable name: uppercase letters, digits and '_', starting with a letter (set env_prefix or rename the attribute)" unless ENV_NAME_RE.match?(env)
          if FEATURE_FLAG_RE.match?(env)
            warnings << "#{env} looks like a feature flag; flags that change without a rollout belong in a flag " \
              "service, not in environment configuration (SPEC §10)"
          end

          before = problems.size
          check_constraint_types(m, type, env, attr, problems)
          next if problems.size > before

          constraints = {}
          %i[min max min_length max_length pattern schemes min_items max_items item_min item_max].each do |k|
            constraints[k] = m[k] unless m[k].nil?
          end
          if %w[int float].include?(type)
            %i[min max].each do |k|
              next if constraints[k].nil?
              next if type == "int" ? constraints[k].is_a?(Integer) : constraints[k].is_a?(Numeric)

              problems << "#{env}: #{k} #{constraints[k].inspect} is not #{type == "int" ? "an integer" : "a number"}" \
                "#{"; for a duration, add type: :duration to `describe :#{attr}`" if constraints[k].is_a?(String)}"
              constraints.delete(k)
            end
          end
          check_item_bounds(type, items, constraints, problems, env)
          constraints[:values] = m[:values].map(&:to_s) if m[:values]
          if type == "duration"
            %i[min max].each do |k|
              next if constraints[k].nil?

              ns = Duration.to_ns(constraints[k])
              if ns.nil? || ns.negative?
                problems << "#{env}: #{k} #{constraints[k].inspect} is not a duration"
                constraints.delete(k)
              else
                constraints[k] = Duration.format_go(ns)
              end
            end
          end
          if type == "json"
            schema = schema_from(m, problems, env)
            constraints[:schema] = schema if schema
          elsif m[:schema] || m[:json_schema]
            problems << "#{env}: schema applies only to json variables"
          end
          constraints[:schemes] = constraints[:schemes].map(&:to_s) if constraints[:schemes]

          regexp = nil
          if constraints[:pattern]
            constraints[:pattern] = constraints[:pattern].source if constraints[:pattern].is_a?(Regexp)
            if type != "string"
              problems << "#{env}: pattern applies only to string variables"
            else
              begin
                regexp = RE2.compile(constraints[:pattern])
              rescue RE2::Unsupported => e
                problems << "#{env}: pattern is not RE2: #{e.message}"
              end
            end
          end
          problems << "#{env}: enum needs a non-empty values list" if type == "enum" && Array(constraints[:values]).empty?
          if type != "enum" && constraints[:values]
            problems << "#{env}: values applies only to enum variables"
          end

          secret = m[:secret] == true
          required = klass.required_attributes.include?(attr) && default.nil?
          if secret && !default.nil?
            problems << "#{env}: a secret must not have a default (it would ship in the image)"
          end
          if secret && m[:examples]
            problems << "#{env}: a secret must not have examples"
          end
          deprecated = normalize_deprecated(m[:deprecated])

          var = VarDecl.new(
            attr: attr, name: env, type: type, description: desc.to_s, secret: secret, required: required,
            default: default, constraints: constraints, group: m[:group]&.to_s,
            examples: m[:examples]&.map(&:to_s), config_key: m[:config_key]&.to_s || "#{klass.config_name}.#{attr}",
            deprecated: deprecated, items: items, regexp: regexp, coercion: coercion_for(type, items),
            lenient_duration: type == "duration"
          )

          if !default.nil? && !secret
            cv, failure = Values.from_typed(var, default)
            if failure
              problems << if type == "enum"
                "#{env}: default #{default.inspect} is not one of #{constraints[:values].join(", ")}"
              else
                "#{env}: default #{default.inspect} is not a valid #{type}"
              end
            else
              Values.check(var, cv).each { |f| problems << "#{env}: default #{f.message}" }
            end
          end
          vars << var
        end

        files = klass.docuconf_file_decls.values
        check_files(klass, files, vars, problems)
        overlays = klass.docuconf_overlay_decls.values
        check_overlays(overlays, files, vars, problems)

        raise DeclarationError, problems unless problems.empty?

        new(klass, vars, files, nested, warnings, overlays)
      end

      def self.env_name(klass, attr)
        prefix = klass.env_prefix.to_s
        prefix.empty? ? attr.to_s.upcase : "#{prefix}_#{attr.to_s.upcase}"
      end

      # Contract type and list item type from the docuconf metadata, then the
      # anyway_config coercion, then the default value.
      def self.infer_type(m, coercion, default)
        if m[:type]
          t = m[:type].to_s
          t = TYPE_ALIASES.fetch(t, t)
          return [nil, nil, "unknown type #{m[:type].inspect}; one of #{VAR_TYPES.join(", ")}"] unless VAR_TYPES.include?(t)

          items = nil
          if t == "list"
            items = (m[:items] || list_items(coercion, default)).to_s
            items = TYPE_ALIASES.fetch(items, items)
            return [nil, nil, "list items must be string or int"] unless %w[string int].include?(items)
          end
          return [t, items, nil]
        end

        if coercion
          spec = coercion.is_a?(Hash) ? coercion : {type: coercion}
          if spec[:array]
            items = (m[:items] || COERCION_TYPES[spec[:type]] || (spec[:type].nil? ? "string" : nil)).to_s
            items = TYPE_ALIASES.fetch(items, items)
            return [nil, nil, "list items must be string or int, not #{spec[:type].inspect}"] unless %w[string int].include?(items)

            return ["list", items, nil]
          end
          t = COERCION_TYPES[spec[:type]]
          return [nil, nil, "coercion #{spec[:type].inspect} has no contract type; add type: to describe"] unless t

          t = "enum" if t == "string" && m[:values]
          return [t, nil, nil]
        end

        return ["enum", nil, nil] if m[:values]

        # No type, coercion or typed default: let the constraints decide, so
        # `describe :port, "...", min: 1, max: 65535` is an int, not an
        # unbounded string.
        if default.nil? || default.is_a?(String)
          inferred = type_from_constraints(m, default)
          return inferred if inferred
        end

        case default
        when Integer then ["int", nil, nil]
        when Float then ["float", nil, nil]
        when true, false then ["bool", nil, nil]
        when Array
          items = (m[:items] || list_items(nil, default)).to_s
          items = TYPE_ALIASES.fetch(items, items)
          ["list", items, nil]
        else
          if defined?(::ActiveSupport::Duration) && default.is_a?(::ActiveSupport::Duration)
            ["duration", nil, nil]
          else
            ["string", nil, nil]
          end
        end
      end

      # The type the constraints imply, or nil: min/max with Integer bounds
      # is int, with Float bounds float, with duration strings duration;
      # min_items/max_items is a list (of int with item_min/item_max);
      # schemes is a url.
      #
      # With a String default, only bounds decide, and only when the
      # default reads as that type ("8080" for an int, "30s" for a
      # duration).
      def self.type_from_constraints(m, default = nil)
        if default.is_a?(String)
          t = type_from_constraints(m.slice(:min, :max))
          ok = case t&.first
          when "int" then Values::INT_RE.match?(default)
          when "float" then Values::FLOAT_RE.match?(default)
          when "duration" then !Duration.to_ns(default).nil?
          end
          return ok ? t : nil
        end

        if m.key?(:item_min) || m.key?(:item_max)
          return ["list", "int", nil]
        elsif m.key?(:min_items) || m.key?(:max_items)
          return ["list", (m[:items] || "string").to_s, nil]
        elsif m.key?(:schemes)
          return ["url", nil, nil]
        end

        bounds = m.values_at(:min, :max).compact
        return nil if bounds.empty?

        if bounds.all?(Integer)
          ["int", nil, nil]
        elsif bounds.all?(Numeric)
          ["float", nil, nil]
        elsif bounds.all? { |b| b.is_a?(String) || (defined?(::ActiveSupport::Duration) && b.is_a?(::ActiveSupport::Duration)) } &&
            bounds.all? { |b| Duration.to_ns(b) }
          ["duration", nil, nil]
        end
      end

      # Which types each constraint applies to (pattern, values, schema and
      # item bounds are checked where they are read).
      CONSTRAINT_TYPES = {
        %i[min max] => ["int, float or duration", %w[int float duration]],
        %i[min_length max_length] => ["string", %w[string]],
        %i[schemes] => ["url", %w[url]],
        %i[min_items max_items] => ["list", %w[list]]
      }.freeze

      # A constraint that cannot apply to the variable's type would be
      # dropped from the contract and the boot check; reject it instead.
      def self.check_constraint_types(m, type, env, attr, problems)
        CONSTRAINT_TYPES.each do |keys, (label, types)|
          given = keys.select { |k| m.key?(k) }
          next if given.empty? || types.include?(type)

          names = given.join("/")
          problems << "#{env}: #{names} #{given.size > 1 ? "apply" : "applies"} to #{label} variables, but #{env} is " \
            "a #{type} (from its coercion or default). Add type: to `describe :#{attr}` (for example type: :#{types.first}), " \
            "or give a default of that type"
        end
      end

      def self.list_items(coercion, default)
        if coercion.is_a?(Hash) && coercion[:type]
          COERCION_TYPES.fetch(coercion[:type], coercion[:type].to_s)
        elsif default.is_a?(Array) && !default.empty? && default.all?(Integer)
          "int"
        else
          "string"
        end
      end

      # The anyway_config coercion docuconf installs for an attribute the
      # team gave none, so the host binds exactly the contract type.
      def self.coercion_for(type, items)
        case type
        when "string", "enum", "url" then :string
        when "int" then :integer
        when "float" then :float
        when "bool" then :boolean
        when "duration" then :duration
        when "json" then :json
        when "list" then {type: items == "int" ? :integer : :string, array: true}
        end
      end

      def self.schema_from(m, problems, label)
        schema =
          if m[:json_schema]
            Schema.deep_stringify(m[:json_schema])
          elsif m[:schema]
            begin
              Schema.to_json_schema(m[:schema])
            rescue ArgumentError => e
              problems << "#{label}: #{e.message}"
              return nil
            end
          end
        return nil unless schema

        Schema.problems(schema).each { |p| problems << "#{label}: schema #{p}" }
        schema
      end

      # itemMin and itemMax bound each item of an int list (SPEC §4.3),
      # within the 64-bit range every int must fit.
      def self.check_item_bounds(type, items, constraints, problems, label, names: {item_min: "item_min", item_max: "item_max"})
        bounds = %i[item_min item_max].select { |k| constraints.key?(k) }
        return if bounds.empty?

        unless type == "list" && items == "int"
          problems << "#{label}: #{names[:item_min]} and #{names[:item_max]} apply only to lists of int"
          bounds.each { |k| constraints.delete(k) }
          return
        end
        bounds.each do |k|
          next if constraints[k].is_a?(Integer) && Values::INT64.cover?(constraints[k])

          problems << "#{label}: #{names[k]} #{constraints[k].inspect} is not a 64-bit integer"
          constraints.delete(k)
        end
        lo, hi = constraints.values_at(:item_min, :item_max)
        problems << "#{label}: #{names[:item_min]} #{lo} is above #{names[:item_max]} #{hi}" if lo && hi && lo > hi
      end

      def self.normalize_deprecated(d)
        case d
        when nil, false then nil
        when String then {message: d}
        when Hash then {message: d[:message].to_s, replaced_by: d[:replaced_by]&.to_s}
        else {message: d.to_s}
        end
      end

      def self.check_overlays(overlays, files, vars, problems)
        return if overlays.empty?

        mounts = files.to_h { |f| [f.mount_dir, "file #{f.name}"] }
        overlays.each do |o|
          label = "overlay #{o.name}"
          problems << "#{label}: name must be a DNS label: lowercase letters, digits and '-', at most 42 characters, starting with a letter and ending with a letter or digit (e.g. serving-tls)" unless INPUT_NAME_RE.match?(o.name)
          if o.description && o.description.strip.length < 5
            problems << "#{label}: description must be at least 5 characters"
          end
          unless o.format == OverlayDecl::FORMAT
            problems << "#{label}: format must be yaml; anyway_config layers YAML config files"
          end
          problems << "#{label}: reload must be restart or watch" unless %w[restart watch].include?(o.reload)
          if !ABS_PATH_RE.match?(o.path) || o.path.split("/").any? { |s| s == "." || s == ".." } ||
              o.path.include?("//") || o.path.end_with?("/")
            problems << "#{label}: path #{o.path.inspect} must be absolute and normalised"
            next
          end
          dir = o.mount_dir
          problems << "#{label}: mount directory #{dir} is reserved; mounting there would hide the image's files" if RESERVED_DIRS.include?(dir)
          if mounts[dir]
            problems << "#{label}: shares mount directory #{dir} with #{mounts[dir]}; one mount would hide the other"
          end
          mounts[dir] ||= label
        end
        vars.each do |v|
          next if v.secret

          parts = v.config_key.split(OverlayDecl::KEY_SEPARATOR, -1)
          if parts.any?(&:empty?) || parts.size > MAX_KEY_DEPTH
            problems << "#{v.name}: configKey #{v.config_key.inspect} must be at most #{MAX_KEY_DEPTH} non-empty " \
              "parts separated by \".\" to be set from an overlay"
          end
        end
      end

      def self.check_files(klass, files, vars, problems)
        mounts = {}
        files.each do |f|
          label = "file #{f.name}"
          problems << "#{label}: name must be a DNS label: lowercase letters, digits and '-', at most 42 characters, starting with a letter and ending with a letter or digit (e.g. serving-tls)" unless INPUT_NAME_RE.match?(f.name)
          problems << "#{label}: description must be at least 5 characters" if f.description.to_s.strip.length < 5
          if !ABS_PATH_RE.match?(f.path) || f.path.split("/").any? { |s| s == "." || s == ".." } ||
              f.path.include?("//") || f.path.end_with?("/")
            problems << "#{label}: path #{f.path.inspect} must be absolute and normalised"
          else
            dir = f.mount_dir
            problems << "#{label}: mount directory #{dir} is reserved; mounting there would hide the image's files" if RESERVED_DIRS.include?(dir)
            if mounts[dir]
              problems << "#{label}: shares mount directory #{dir} with #{mounts[dir]}; one mount would hide the other"
            end
            mounts[dir] ||= f.name
          end
          problems << "#{label}: reload must be restart or watch" unless %w[restart watch].include?(f.reload)
          if f.max_size && !(f.max_size.is_a?(Integer) && f.max_size.positive?)
            problems << "#{label}: max_size must be a positive number of bytes"
          end
          if f.path_env
            problems << "#{label}: path_env #{f.path_env} is not a valid environment variable name" unless ENV_NAME_RE.match?(f.path_env)
            if vars.any? { |v| v.name == f.path_env }
              problems << "#{label}: path_env #{f.path_env} must not also be a declared variable"
            end
          end
          o = f.options
          case f.type
          when "config"
            problems << "#{label}: format must be json, yaml or toml" unless %w[json yaml toml].include?(o[:format])
          when "tls"
            bad = Array(o[:key_algorithms]) - KEY_ALGORITHMS
            problems << "#{label}: key_algorithms must be among #{KEY_ALGORITHMS.join(", ")}" unless bad.empty?
            if o[:min_remaining] && !Duration::CONTRACT_FORM.match?(o[:min_remaining])
              problems << "#{label}: min_remaining #{o[:min_remaining].inspect} is not a duration"
            end
          when "caBundle"
            mc = o[:min_certificates]
            problems << "#{label}: min_certificates must be at least 1" unless mc.nil? || (mc.is_a?(Integer) && mc >= 1)
          when "keystore"
            problems << "#{label}: format must be pkcs12 or jks" unless %w[pkcs12 jks].include?(o[:format])
            pv = o[:password_var]
            if pv.is_a?(Symbol)
              v = vars.find { |x| x.attr == pv }
              if v.nil?
                problems << "#{label}: password_var :#{pv} is not a declared attribute of #{klass.name}"
              elsif !v.secret
                problems << "#{label}: password_var #{v.name} must be a secret variable (secret :#{pv})"
              end
            elsif pv && !ENV_NAME_RE.match?(pv.to_s)
              problems << "#{label}: password_var #{pv.inspect} is not a valid environment variable name"
            end
          when "text"
            if o[:pattern]
              o[:pattern] = o[:pattern].source if o[:pattern].is_a?(Regexp)
              if (p = RE2.problem(o[:pattern]))
                problems << "#{label}: pattern is not RE2: #{p}"
              end
            end
          end
        end
      end
    end
  end
end
