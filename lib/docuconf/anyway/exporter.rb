# frozen_string_literal: true

require "erb"
require "yaml"
require "date"
require "pathname"

module Docuconf
  module Anyway
    # Builds a contract (SPEC §4) from one or more Docuconf::Anyway config
    # classes, plus the YAML files anyway_config reads from the image
    # (SPEC §4.4): values in an always-loaded file, or in its
    # default_environmental_key section, become defaults; values in a
    # per-environment section become profile defaults selected by RAILS_ENV.
    class Exporter
      NAME_RE = /\A[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?\z/
      KNOWN_ENVIRONMENTS = %w[development test production].freeze

      attr_reader :warnings

      # name:            service name (a DNS label)
      # classes:         config classes; default: every loaded class that includes Docuconf::Anyway
      # app_version:     metadata.appVersion
      # root:            directory the YAML paths are relative to (Rails.root, or the working directory)
      # profiles:        read config/<name>.yml (default true)
      # selector:        the variable that picks the profile (default RAILS_ENV)
      # default_profile: the profile in effect when the selector is unset (default development)
      def initialize(name:, classes: nil, app_version: nil, root: nil, profiles: true, selector: "RAILS_ENV",
        default_profile: "development")
        @name = name.to_s
        @classes = classes
        @app_version = app_version
        @root = root ? Pathname.new(root) : Pathname.new(Dir.pwd)
        @profiles = profiles
        @selector = selector
        @default_profile = default_profile
        @warnings = []
      end

      def classes
        list = @classes || Docuconf::Anyway.configs.select do |k|
          k.name && (!k.config_attributes.empty? || !k.docuconf_file_decls.empty?)
        end
        list.sort_by { |k| k.name.to_s }
      end

      # The contract as data (Hash with String keys).
      def contract
        problems = []
        problems << "service name #{@name.inspect} must be a DNS label (#{NAME_RE.source})" unless NAME_RE.match?(@name)

        decls = []
        classes.each do |k|
          decls << k.docuconf_declaration
        rescue DeclarationError => e
          problems.concat(e.problems.map { |p| "#{k.name}: #{p}" })
        end

        vars = {}
        var_decls = {}
        files = {}
        profile_defaults = Hash.new { |h, k| h[k] = {} }

        decls.each do |d|
          base, by_profile = @profiles ? yaml_values(d.klass) : [{}, {}]

          d.vars.each do |v|
            if vars.key?(v.name)
              problems << "#{v.name} is declared by both #{var_decls[v.name].attr} and #{d.klass.name}.#{v.attr}"
              next
            end
            h = v.to_contract
            key = v.attr.to_s
            if base.key?(key) && !base[key].nil?
              if v.secret
                problems << "#{v.name}: a secret must not have a value in #{yaml_path(d.klass)}; it would ship in the image"
              else
                cv = contract_value(v, base[key], "#{yaml_path(d.klass)}", problems)
                unless cv.nil?
                  h["default"] = cv
                  h.delete("required")
                end
              end
            end
            vars[v.name] = h
            var_decls[v.name] = v
          end

          by_profile.each do |profile, values|
            values.each do |key, raw|
              v = d.var(key)
              next unless v
              next if raw.nil?

              if v.secret
                problems << "#{v.name}: a secret must not have a value in the #{profile} section of " \
                  "#{yaml_path(d.klass)}; it would ship in the image"
                next
              end
              cv = contract_value(v, raw, "#{yaml_path(d.klass)} (#{profile})", problems)
              profile_defaults[profile.to_s][v.name] = cv unless cv.nil?
            end
          end

          d.files.each do |f|
            if files.key?(f.name)
              problems << "file #{f.name} is declared twice"
              next
            end
            password_env = nil
            pv = f[:password_var]
            if pv.is_a?(Symbol)
              password_env = d.var(pv)&.name
            elsif pv
              password_env = pv.to_s
            end
            files[f.name] = [f, f.to_contract(password_env: password_env)]
          end
        end

        check_files(files, var_decls, problems)

        unless profile_defaults.empty?
          unless vars.key?(@selector)
            vars[@selector] = {
              "type" => "string",
              "description" => "Environment the app runs in; selects the matching section of its config/*.yml files",
              "default" => @default_profile
            }
          end
        end

        raise DeclarationError, problems unless problems.empty?

        metadata = {"name" => @name}
        metadata["appVersion"] = @app_version.to_s if @app_version
        metadata["generator"] = {"language" => "ruby", "sdk" => SDK_NAME, "version" => VERSION}
        out = {
          "apiVersion" => API_VERSION,
          "kind" => "ConfigContract",
          "metadata" => metadata,
          "vars" => vars.sort.to_h
        }
        out["files"] = files.sort.to_h { |n, (_, h)| [n, h] } unless files.empty?
        unless profile_defaults.empty?
          out["profiles"] = {
            "selector" => @selector,
            "default" => @default_profile,
            "defaults" => profile_defaults.sort.to_h { |p, m| [p, m.sort.to_h] }
          }
        end
        out
      end

      def package
        pkg = @name.tr("-", "_")
        pkg = "svc_#{pkg}" if pkg.match?(/\A[0-9]/) || pkg == "contract"
        pkg
      end

      # The contract file (CUE text).
      def to_cue(package: nil)
        CUE.document(contract, package: package || self.package)
      end

      private

      def contract_value(var, raw, where, problems)
        cv, failure = Values.from_typed(var, raw)
        if failure
          problems << "#{var.name}: #{where}: #{failure.message}"
          return nil
        end
        failures = Values.check(var, cv)
        unless failures.empty?
          failures.each { |f| problems << "#{var.name}: #{where}: #{f.message}" }
          return nil
        end
        var.type == "duration" ? Duration.format_go(cv) : cv
      end

      def yaml_path(klass)
        path = ::Anyway::Settings.default_config_path.call(klass.config_name)
        path = Pathname.new(path.to_s)
        path = @root.join(path) if path.relative?
        path.cleanpath.relative_path_from(@root.cleanpath).to_s
      rescue ArgumentError
        path.to_s
      end

      # Returns [base values, {profile => values}] from the class's YAML file.
      def yaml_values(klass)
        sources = klass.configuration_sources
        return [{}, {}] if sources && !sources.include?(:yml)

        path = Pathname.new(::Anyway::Settings.default_config_path.call(klass.config_name).to_s)
        path = @root.join(path) if path.relative?
        return [{}, {}] unless path.file?

        data = YAML.safe_load(ERB.new(path.read).result, permitted_classes: [Date, Time, Symbol], aliases: true) || {}
        return [{}, {}] unless data.is_a?(Hash)

        data = data.transform_keys(&:to_s)
        default_key = ::Anyway::Settings.default_environmental_key&.to_s
        known = Array(::Anyway::Settings.known_environments || KNOWN_ENVIRONMENTS).map(&:to_s) | KNOWN_ENVIRONMENTS
        environmental = data.keys.any? { |k| known.include?(k) } || (default_key && data.key?(default_key))
        return [stringify(data), {}] unless environmental

        base = default_key && data[default_key].is_a?(Hash) ? stringify(data[default_key]) : {}
        profiles = {}
        data.each do |k, v|
          next if k == default_key || !v.is_a?(Hash)

          profiles[k] = stringify(v)
        end
        [base, profiles]
      end

      def stringify(h) = h.to_h.transform_keys(&:to_s)

      def check_files(files, vars, problems)
        mounts = {}
        files.each_value do |f, _|
          dir = f.mount_dir
          if mounts[dir] && mounts[dir] != f.name
            problems << "file #{f.name}: shares mount directory #{dir} with #{mounts[dir]}"
          end
          mounts[dir] ||= f.name
          if f.path_env && vars.key?(f.path_env)
            problems << "file #{f.name}: path_env #{f.path_env} must not also be a declared variable"
          end
          pv = f[:password_var]
          if f.type == "keystore" && pv.is_a?(String)
            v = vars[pv]
            if v.nil?
              problems << "file #{f.name}: password_var #{pv} is not a declared variable"
            elsif !v.secret
              problems << "file #{f.name}: password_var #{pv} must be a secret variable"
            end
          end
        end
      end
    end

    # Exports a contract as CUE text. See Exporter#initialize for options.
    def self.export(name:, package: nil, **options)
      Exporter.new(name: name, **options).to_cue(package: package)
    end
  end
end
