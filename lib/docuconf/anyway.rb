# frozen_string_literal: true

require "anyway_config"
require "set"

require_relative "anyway/version"
require_relative "anyway/errors"
require_relative "anyway/duration"
require_relative "anyway/re2"
require_relative "anyway/schema"
require_relative "anyway/values"
require_relative "anyway/declaration"
require_relative "anyway/dsl"
require_relative "anyway/tls"
require_relative "anyway/files"
require_relative "anyway/overlays"
require_relative "anyway/watcher"
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
        # These instances are thrown away: do not start file watchers for them.
        Thread.current[:docuconf_no_watch] = true
        classes.each do |k|
          k.new
        rescue ValidationError => e
          violations.concat(e.violations)
        end
        Thread.current[:docuconf_no_watch] = nil
        return true if violations.empty?

        error = ValidationError.new(violations)
        write_termination_log(error.message)
        raise error
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
        super
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
        Overlays.check_location!(decl.overlays, opts[:config_path]) unless decl.overlays.empty?
        docuconf_loaders(decl).each do |(id, loader)|
          if id == OverlayLoader::ID
            next if decl.overlays.empty?

            ::Anyway::Utils.deep_merge!(base_config, loader.call(**opts, docuconf_config: self))
            next
          end
          next if filter && !filter.include?(id)

          data = loader.call(**opts)
          docuconf_take_env(decl, data) if id == :env
          ::Anyway::Utils.deep_merge!(base_config, data)
        end
        @docuconf_loaded = base_config.dup
        base_config
      end

      private

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
        if Docuconf::Anyway.skip_validation?
          Validator.new(self).load_files_leniently
          return
        end

        violations = Validator.new(self).run
        unless violations.empty?
          error = ValidationError.new(violations)
          # A rejected overlay reload keeps the running config: not a crash.
          Docuconf::Anyway.write_termination_log(error.message) unless Thread.current[:docuconf_reloading]
          raise error
        end
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

Anyway::Config.extend(Docuconf::Anyway::MissingIncludeGuard)

module Docuconf
  # Short name for schema helpers: `schema: {plans: Docuconf::S.array(...)}`.
  S = Anyway::Schema
end
