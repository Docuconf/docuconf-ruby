# frozen_string_literal: true

require "yaml"
require "pathname"

module Docuconf
  module Anyway
    # A config-file overlay (SPEC §4.7): one more YAML file, mounted by the
    # platform, that anyway_config layers after config/<name>.yml (and Rails
    # credentials) and before the environment.
    class OverlayDecl
      KEY_SEPARATOR = "."
      FORMAT = "yaml"

      attr_reader :name, :path, :reload, :description, :format

      def initialize(name:, path:, reload:, description:, format:)
        @name = name
        @path = path
        @reload = reload
        @description = description
        @format = format
      end

      def key_separator = KEY_SEPARATOR

      def mount_dir = File.dirname(path)

      def to_contract
        h = {"format" => format}
        h["description"] = description if description
        h["path"] = path
        h["keySeparator"] = key_separator
        h["reload"] = reload if reload != "restart"
        h
      end

      def ==(other)
        other.is_a?(OverlayDecl) && other.to_contract == to_contract && other.name == name
      end
      alias_method :eql?, :==

      def hash = [name, to_contract].hash
    end

    # Reading overlays: each declared variable's value sits at its configKey
    # (`billing.port` is `{billing: {port: ...}}`), as the platform's
    # #Render writes it.
    module Overlays
      Failure = Values::Failure

      module_function

      # The overlay's path, under DOCUCONF_FILE_ROOT when that is set.
      def resolve_path(overlay, env = ENV)
        root = env["DOCUCONF_FILE_ROOT"]
        root && !root.empty? ? File.join(root, overlay.path) : overlay.path
      end

      # Returns [{attr => value}, failures] for one overlay and one config
      # class. A missing file is no values and no failures.
      def read(decl, overlay, path, value_failures = {})
        data, failure = parse(path)
        return [{}, failure ? [failure] : []] if data.nil?

        [values_for(decl, overlay, data, value_failures), []]
      end

      # Returns [Hash, nil], [nil, nil] for a missing file, or [nil, Failure].
      def parse(path)
        content = File.binread(path)
        data = YAML.safe_load(content.force_encoding(Encoding::UTF_8).delete_prefix(Files::BOM), aliases: false)
        data = {} if data.nil?
        return [data, nil] if data.is_a?(Hash)

        [nil, Failure.new(:file_malformed, "#{path}: the top level must be a mapping of config keys")]
      rescue Errno::ENOENT, Errno::ENOTDIR
        [nil, nil]
      rescue Errno::EACCES
        [nil, Failure.new(:file_unreadable, "#{path}: #{Files::UNREADABLE_HINT}")]
      rescue SystemCallError, IOError => e
        [nil, Failure.new(:file_unreadable, "#{path}: #{e.message}")]
      rescue Psych::Exception, EncodingError => e
        [nil, Failure.new(:file_malformed, "#{path} is not valid YAML: #{e.message.lines.first&.strip}")]
      end

      # Values that do not even parse as their type are left out (so
      # anyway_config's coercion never sees them) and returned as failures
      # by attribute, in `failures` when given.
      def values_for(decl, overlay, data, failures = {})
        out = {}
        decl.vars.each do |var|
          found, value = dig(data, var.config_key.split(overlay.key_separator))
          next unless found

          if var.secret
            Docuconf::Anyway.warn("overlay #{overlay.name} sets the secret #{var.name}, which is ignored: " \
              "overlays are ConfigMaps, so secrets come from the environment")
            next
          end
          _, failure = Values.from_typed(var, value) unless value.nil?
          if failure
            failures[var.attr] = Failure.new(failure.code, "#{failure.message} (in overlay #{overlay.name})")
            next
          end
          out[var.attr.to_s] = value
        end
        out
      end

      def dig(data, parts)
        node = data
        parts.each do |p|
          return [false, nil] unless node.is_a?(Hash) && node.key?(p)

          node = node[p]
        end
        [true, node]
      end

      # The platform mounts the overlay's directory, which hides what the
      # image has there (SPEC §4.7): refuse the app's own directory, the
      # directory anyway_config reads config/<name>.yml from, and any of
      # their ancestors.
      def check_location!(overlays, config_path, env = ENV)
        app_root = File.expand_path(::Anyway::Settings.app_root.to_s)
        own = [app_root]
        own << File.dirname(File.expand_path(config_path.to_s, app_root)) if config_path && !config_path.to_s.empty?
        problems = []
        overlays.each do |o|
          dir = File.expand_path(File.dirname(resolve_path(o, env)))
          next unless own.any? { |d| d == dir || d.start_with?("#{dir.chomp("/")}/") }

          problems << "overlay #{o.name}: #{o.path} is in the app's own directory (#{dir}); mounting it would " \
            "hide the app's files. Use a directory of its own, such as /etc/<app>/overlay"
        end
        raise DeclarationError, problems unless problems.empty?
      end
    end

    # The anyway_config loader for overlays, registered in Anyway.loaders as
    # :docuconf_overlay just before :env. Docuconf::Anyway classes call it
    # with themselves as `docuconf_config:`; for other classes it loads
    # nothing.
    class OverlayLoader < ::Anyway::Loaders::Base
      ID = :docuconf_overlay

      def call(docuconf_config: nil, **)
        return {} unless docuconf_config

        decl = docuconf_config.class.docuconf_declaration
        out = {}
        failures = docuconf_config.docuconf_overlay_failures
        failures.clear
        value_failures = docuconf_config.docuconf_overlay_value_failures
        value_failures.clear
        decl.overlays.each do |o|
          path = Overlays.resolve_path(o)
          values, problems = Overlays.read(decl, o, path, value_failures)
          values.each_key { |k| value_failures.delete(k.to_sym) }
          problems.each { |f| failures << [o, f] }
          trace!(ID, path: o.path) { values }
          ::Anyway::Utils.deep_merge!(out, values)
        end
        out
      end

      # Registers the loader before :env. Returns false when anyway_config
      # has frozen its loaders already (Rails, after initialization); the
      # overlay is then still loaded, in the same position, by
      # Docuconf::Anyway#load_from_sources.
      def self.register(loaders = ::Anyway.loaders)
        return true if loaders.keys.include?(ID)

        if loaders.keys.include?(:env)
          loaders.insert_before(:env, ID, self)
        else
          loaders.append(ID, self)
        end
        true
      rescue FrozenError
        false
      end
    end
  end
end
