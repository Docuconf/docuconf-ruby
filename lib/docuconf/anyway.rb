# frozen_string_literal: true

require "anyway_config"
require "set"

require_relative "anyway/version"
require_relative "anyway/errors"
require_relative "anyway/duration"
require_relative "anyway/re2"
require_relative "anyway/schema"
require_relative "anyway/key_set"
require_relative "anyway/values"
require_relative "anyway/docs"
require_relative "anyway/declaration"
require_relative "anyway/dsl"
require_relative "anyway/tls"
require_relative "anyway/files"
require_relative "anyway/overlays"
require_relative "anyway/watcher"
require_relative "anyway/hints"
require_relative "anyway/validator"
require_relative "anyway/cue"
require_relative "anyway/exporter"
require_relative "anyway/contract"

module Docuconf
  # docuconf for anyway_config: typed configuration contracts between a
  # Ruby app and the Kubernetes platform that runs it.
  #
  #   class BillingConfig < Anyway::Config
  #     include Docuconf::Anyway
  #
  #     config_name :billing
  #     attr_config :database_url, port: 8080
  #     required :database_url
  #
  #     describe :database_url, "Primary Postgres connection string", type: :url, schemes: %w[postgres]
  #     secret :database_url
  #     describe :port, "HTTP listen port", min: 1, max: 65535
  #   end
  #
  # anyway_config keeps loading, parsing and binding. docuconf adds
  # descriptions, secrets and constraints, checks every variable and file
  # input at load time (reporting all problems together), and exports the
  # declaration as a CUE contract.
  module Anyway
    def self.included(base)
      unless base.is_a?(Class) && base <= ::Anyway::Config
        raise ArgumentError, "include Docuconf::Anyway in an Anyway::Config subclass"
      end

      base.extend(ClassMethods)
      base.include(InstanceMethods)
      base.on_load :docuconf_validate!
      register(base)
    end

    # Every class that includes Docuconf::Anyway, and their subclasses.
    def self.configs
      @configs ||= []
    end

    def self.register(klass)
      configs << klass unless configs.include?(klass)
    end

    module ClassMethods
      def inherited(subclass)
        super
        Docuconf::Anyway.register(subclass)
      end

      # Loads the config from an explicit environment instead of ENV, for
      # tests: no process environment is read or changed, no file watcher
      # starts and no termination log is written. `file_root` prefixes
      # absolute file and overlay paths (as DOCUCONF_FILE_ROOT does).
      # config/<name>.yml and credentials are still read, as usual. Raises
      # ValidationError with every problem.
      #
      #   OrdersConfig.from_env({"PORT" => "0"})  # => raises, PORT [out_of_range]
      #   OrdersConfig.from_env("PORT" => "0")  # the same, without braces
      def from_env(env = {}, file_root: nil, overrides: nil, **vars)
        env = env.to_h.merge(vars).to_h { |k, v| [k.to_s, v.nil? ? nil : v.to_s] }.compact
        env["DOCUCONF_FILE_ROOT"] = file_root.to_s if file_root
        Docuconf::Anyway.with_load_env(env.freeze) { new(overrides) }
      end

      # Loads the config, or prints every problem and exits 1: the boot
      # one-liner.
      #
      #   CONFIG = OrdersConfig.load!
      #
      # On failure it prints `docuconf: N configuration problems:` and one
      # line per problem to stderr, writes the termination log and exits 1,
      # without a backtrace.
      def load!(overrides = nil)
        Docuconf::Anyway.exit_on_failure { new(overrides) }
      end
    end

    class << self
      # Set by `docuconf export` and `rails docuconf:export`: classes can be
      # loaded and exported without a real environment.
      attr_accessor :export_mode

      # Whether reload: :watch inputs are watched (default true).
      attr_writer :watch_files

      def watch_files = @watch_files.nil? ? true : @watch_files

      # Boot validation is skipped in export mode, when DOCUCONF_SKIP_VALIDATION
      # is set, and when anyway_config suppresses required validations (as it
      # does for assets:precompile via SECRET_KEY_BASE_DUMMY or
      # ANYWAY_SUPPRESS_VALIDATIONS).
      def skip_validation?(env = ENV)
        return true if export_mode
        return true if %w[1 true yes].include?(env["DOCUCONF_SKIP_VALIDATION"].to_s.downcase)

        ::Anyway::Settings.suppress_required_validations ? true : false
      end

      # Loads every config class (or the given ones) and raises one
      # ValidationError listing the problems of all of them.
      def validate_all!(classes = nil)
        classes ||= configs.select { |k| k.name && (!k.config_attributes.empty? || !k.docuconf_file_decls.empty?) }
        violations = []
        problems = []
        # These instances are thrown away: do not start file watchers for them.
        begin
          Thread.current[:docuconf_no_watch] = true
          classes.each do |k|
            k.new
          rescue ValidationError => e
            violations.concat(e.violations)
          rescue DeclarationError => e
            problems.concat(classes.size > 1 ? e.problems.map { |p| "#{k.name}: #{p}" } : e.problems)
          end
        ensure
          Thread.current[:docuconf_no_watch] = nil
        end
        raise DeclarationError, problems unless problems.empty?
        return true if violations.empty?

        error = ValidationError.new(violations)
        write_termination_log(error.message)
        raise error
      end

      # Runs the block (loading configs); on a ValidationError or
      # DeclarationError prints the message, writes the termination log and
      # exits 1.
      def exit_on_failure(err: $stderr)
        yield
      rescue ValidationError, DeclarationError => e
        write_termination_log(e.message)
        err.puts e.message
        exit 1
      end

      # Loads every config class (or the given ones), or prints every
      # problem and exits 1.
      def load_all!(classes = nil)
        exit_on_failure { validate_all!(classes) }
      end

      # Loads configs inside the block from `env` instead of ENV.
      def with_load_env(env)
        saved = Thread.current[:docuconf_load_env]
        Thread.current[:docuconf_load_env] = env
        yield
      ensure
        Thread.current[:docuconf_load_env] = saved
      end

      # A duration from a config (ActiveSupport::Duration or seconds) in Go
      # syntax: "30s", "1m30s".
      def format_duration(value)
        ns = Duration.to_ns(value)
        raise ArgumentError, "not a duration: #{value.inspect}" if ns.nil?

        Duration.format_go(ns)
      end

      # Every secret attribute and variable name of every loaded docuconf
      # class, as strings: database_url and DATABASE_URL.
      def secret_names
        configs.each_with_object(Set.new) do |k, out|
          next unless k.name

          decl = begin
            k.docuconf_declaration
          rescue StandardError
            next
          end
          decl.vars.each do |v|
            next unless v.secret

            out << v.attr.to_s << v.name
          end
        end
      end

      # A Rails filter_parameters entry: filters a parameter named like a
      # declared secret.
      def filter_secret_parameter(key, value)
        return unless value.is_a?(String) && !value.frozen?
        return unless secret_names.include?(key.to_s)

        value.replace("[FILTERED]")
      end

      # Restarts reload: :watch threads in a forked child (Puma cluster mode
      # with preload_app!, Unicorn, Resque). Called automatically after
      # Process.fork; call it yourself only for a fork docuconf cannot see.
      def restart_watchers!
        Watcher.restart_all
      end

      # Prints a warning; by default each distinct message only once.
      def warn(message, once: true)
        @warned ||= Set.new
        return if once && @warned.include?(message)

        @warned << message
        Kernel.warn("docuconf: #{message}")
      end
    end

    # Instance behaviour added to the config class.
    module InstanceMethods
      FILTERED = "[FILTERED]"

      # The environment this config was loaded from: ENV, or the map given
      # to .from_env.
      def docuconf_env_source
        @docuconf_env_source || ENV
      end

      def docuconf_isolated? = !@docuconf_env_source.nil?

      # anyway_config's inspect and pp print every value; secrets are shown
      # as [FILTERED].
      def inspect
        "#<#{self.class}:0x#{format("%016x", object_id)} config_name=#{config_name.inspect} " \
          "env_prefix=#{env_prefix.inspect} values=#{docuconf_filtered_values.inspect}>"
      end

      def pretty_print(q)
        q.group(1, "#<#{self.class}", ">") do
          q.breakable
          q.text "config_name=#{config_name.inspect}"
          q.breakable
          q.text "env_prefix=#{env_prefix.inspect}"
          q.breakable
          q.text "values="
          q.pp docuconf_filtered_values
        end
      end

      def docuconf_filtered_values
        secrets = docuconf_secret_attrs
        values.to_h { |k, v| [k, secrets.include?(k.to_sym) && !v.nil? ? FILTERED : v] }
      end

      def docuconf_secret_attrs
        self.class.docuconf_declaration.vars.select(&:secret).map(&:attr)
      rescue StandardError
        self.class.docuconf_var_meta.select { |_, m| m[:secret] }.keys
      end
      # Loaded file inputs, by accessor name. Each also has a reader method.
      def docuconf_files
        @docuconf_files ||= {}
      end

      # The watcher for reload: :watch inputs, if any.
      attr_reader :docuconf_watcher

      # Problems reading config-file overlays in the last load, as
      # [OverlayDecl, Failure] pairs.
      def docuconf_overlay_failures
        @docuconf_overlay_failures ||= []
      end

      # Overlay values that did not parse as their type in the last load, by
      # attribute.
      def docuconf_overlay_value_failures
        @docuconf_overlay_value_failures ||= {}
      end

      # Calls the block with the config whenever a watched overlay changes
      # and its new values pass validation.
      def on_overlay_change(&block)
        docuconf_overlay_listeners << block
        self
      end

      def docuconf_overlay_listeners
        @docuconf_overlay_listeners ||= []
      end

      # Calls the block with the new value whenever a watched file input is
      # reloaded successfully.
      def on_file_change(accessor, &block)
        (docuconf_listeners[accessor.to_sym] ||= []) << block
        self
      end

      def docuconf_listeners
        @docuconf_listeners ||= {}
      end

      def load(overrides = nil)
        @docuconf_overrides = overrides
        @docuconf_env_source ||= Thread.current[:docuconf_load_env]
        super
      rescue ::Anyway::Config::ValidationError, ArgumentError, TypeError, RuntimeError => e
        raise if e.is_a?(ValidationError) || e.is_a?(DeclarationError)

        # An on_load callback (the app's own validation) may put a value in
        # its message: never a secret one.
        scrubbed = docuconf_scrub(e.message)
        raise if scrubbed == e.message

        raise e.exception(scrubbed)
      end

      # Replaces the value of every secret attribute in text.
      def docuconf_scrub(text)
        docuconf_secret_attrs.each do |a|
          v = values[a]
          # A key set's keys, each on its own.
          shown = v.is_a?(KeySet) ? v.keys : [v]
          shown.each do |x|
            x = x.to_s unless x.nil?
            next if x.nil? || x.length < 3

            text = text.gsub(x, FILTERED)
          end
        end
        text
      rescue StandardError
        text
      end

      # Replaces anyway_config's loop over its loaders, so docuconf sees the
      # raw environment strings before coercion: an empty string counts as
      # unset for non-string types (SPEC §5), and a value that fails strict
      # parsing is reported instead of being coerced into something else
      # ("12abc".to_i is 12).
      #
      # Declared overlays are loaded by the :docuconf_overlay loader, just
      # before :env, whatever `configuration_sources` says: declaring an
      # overlay opts in to it.
      def load_from_sources(base_config, **opts)
        decl = self.class.docuconf_declaration
        @docuconf_env = {}
        filter = self.class.configuration_sources
        Overlays.check_location!(decl.overlays, opts[:config_path], docuconf_env_source) unless decl.overlays.empty?
        docuconf_loaders(decl).each do |(id, loader)|
          if id == OverlayLoader::ID
            next if decl.overlays.empty?

            ::Anyway::Utils.deep_merge!(base_config, loader.call(**opts, docuconf_config: self))
            next
          end
          next if filter && !filter.include?(id)

          data = id == :env && docuconf_isolated? ? docuconf_env_data(opts[:env_prefix]) : loader.call(**opts)
          docuconf_take_env(decl, data) if id == :env
          ::Anyway::Utils.deep_merge!(base_config, data)
        end
        @docuconf_loaded = base_config.dup
        base_config
      end

      private

      # What anyway_config's :env loader reads, from the explicit map.
      def docuconf_env_data(prefix)
        ::Anyway::Env.new(type_cast: ::Anyway::NoCast, env_container: docuconf_env_source).fetch(prefix.to_s)
      end

      # anyway_config's loaders, with the overlay loader before :env even if
      # it could not be registered.
      def docuconf_loaders(decl)
        list = []
        ::Anyway.loaders.each { |entry| list << entry }
        return list if decl.overlays.empty? || list.any? { |(id, _)| id == OverlayLoader::ID }

        at = list.index { |(id, _)| id == :env } || list.size
        list.insert(at, [OverlayLoader::ID, OverlayLoader])
      end

      def docuconf_take_env(decl, data)
        decl.vars.each do |var|
          key = var.attr.to_s
          raw = data[key]
          next unless raw.is_a?(String)

          value, failure = Values.from_env(var, raw)
          if value.equal?(Values::UNSET)
            data.delete(key)
          elsif failure
            data.delete(key)
            @docuconf_env[var.attr] = {failure: failure}
          else
            @docuconf_env[var.attr] = {value: value}
            # anyway_config would coerce the raw string again, more leniently
            # than SPEC §5 (it trims csv items, drops trailing empty ones and
            # reads Integer("010") as octal); hand it the value docuconf parsed.
            data[key] = Values.host_value(var, value)
          end
        end
      end

      # anyway_config coerces every loaded value as it writes it; a value
      # from a YAML file or credentials that does not parse (a bad
      # duration, malformed JSON) raises from the caster. For a declared
      # variable, keep the raw value instead: the validator reports it as
      # invalid_type, naming the variable, together with every other
      # problem.
      def write_config_attr(key, val)
        super
      rescue StandardError
        decl = self.class.docuconf_declaration
        raise unless self.class.config_attributes.include?(key.to_sym) && decl.var(key)

        public_send(:"#{key}=", val)
      end

      # docuconf reports missing required attributes itself, together with
      # every other problem.
      def validate_required_attributes!
        nil
      end

      def docuconf_validate!
        env = docuconf_env_source
        if Docuconf::Anyway.skip_validation?(env)
          Validator.new(self, env: env).load_files_leniently
          return
        end

        Hints.warn_typos(self.class, env) unless Thread.current[:docuconf_reloading]
        violations = Validator.new(self, env: env).run
        unless violations.empty?
          error = ValidationError.new(violations)
          # A rejected overlay reload keeps the running config: not a crash.
          # A test loading from an explicit env writes nothing.
          unless Thread.current[:docuconf_reloading] || docuconf_isolated?
            Docuconf::Anyway.write_termination_log(error.message)
          end
          raise error
        end
        return if docuconf_isolated?

        Watcher.start(self) if Docuconf::Anyway.watch_files && !Thread.current[:docuconf_no_watch]
      end
    end
  end
end

require_relative "anyway/railtie" if defined?(::Rails::Railtie)

Docuconf::Anyway::OverlayLoader.register

# :duration reads ISO 8601 (the wire encoding docuconf declares for
# durations; ActiveSupport::Duration.parse when ActiveSupport is loaded) and,
# from YAML or defaults, Go syntax or a number of seconds. :json parses a
# JSON string.
Anyway::TypeRegistry.default.accept(:duration) { |v| Docuconf::Anyway::Duration.cast(v) }
Anyway::TypeRegistry.default.accept(:json) { |v| v.is_a?(String) ? JSON.parse(v) : v }
# :key_set wraps a list of keys in a Docuconf::Anyway::KeySet (a csv string
# from credentials or YAML is split on commas, never trimmed).
Anyway::TypeRegistry.default.accept(:key_set) do |v|
  case v
  when Docuconf::Anyway::KeySet, nil then v
  when String then Docuconf::Anyway::KeySet.new(v.split(",", -1))
  else Docuconf::Anyway::KeySet.new(Array(v).map(&:to_s))
  end
end

Anyway::Config.extend(Docuconf::Anyway::MissingIncludeGuard)

module Docuconf
  # Short name for schema helpers: `schema: {plans: Docuconf::S.array(...)}`.
  S = Anyway::Schema
end
