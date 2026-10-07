# frozen_string_literal: true

module Docuconf
  module Anyway
    # Checks a loaded config instance: every declared variable (from the
    # environment, YAML, credentials or defaults), every required attribute
    # and every file input. Returns all violations together.
    class Validator
      def initialize(config, env: ENV, now: Time.now)
        @config = config
        @klass = config.class
        @env = env
        @now = now
      end

      def run
        decl = @klass.docuconf_declaration
        violations = []
        from_env = @config.instance_variable_get(:@docuconf_env) || {}
        loaded = @config.instance_variable_get(:@docuconf_loaded) || {}

        decl.vars.each do |var|
          add = ->(code, message) { violations << Violation.new(input: var.name, kind: :var, code: code, message: message) }
          info = from_env[var.attr]
          # A value that came from an overlay but did not parse (the
          # environment, when set, wins over it).
          if !info && (f = @config.docuconf_overlay_value_failures[var.attr])
            info = {failure: f}
          end
          if info && info[:failure]
            add.call(info[:failure].code, info[:failure].message)
            next
          end

          if info
            value = info[:value]
            if var.deprecated
              Docuconf::Anyway.warn("#{var.name} is deprecated: #{var.deprecated[:message]}")
            end
          else
            raw = loaded.key?(var.attr.to_s) ? loaded[var.attr.to_s] : @config.public_send(var.attr)
            # Programmatic overrides (Config.new(port: 1)) win over loaded values.
            raw = @config.public_send(var.attr) if overridden?(var.attr)
            if raw.nil? || (raw == "" && var.type != "string")
              add.call(:missing_required, missing_message(var)) if required?(var)
              next
            end
            value, failure = Values.from_typed(var, raw)
            failure = Values.unresolved_reference(var, raw) || failure
            if failure
              add.call(failure.code, failure.message)
              next
            end
          end
          Values.check(var, value).each { |f| add.call(f.code, f.message) }
        end

        declared = decl.vars.map(&:attr)
        (@klass.required_attributes.map { |n| n.to_s } - declared.map(&:to_s)).each do |name|
          val = @config.dig(*name.split(".").map(&:to_sym))
          next unless val.nil? || (val.is_a?(String) && val.empty?)

          violations << Violation.new(input: "#{@klass.config_name}.#{name}", kind: :var, code: :missing_required,
            message: "required, and not set (not part of the contract, e.g. a Rails credential)")
        end

        @config.docuconf_overlay_failures.each do |overlay, f|
          violations << Violation.new(input: overlay.name, kind: :overlay, code: f.code, message: f.message)
        end
        violations.concat(load_files(decl))
        violations
      end

      # Loads file inputs without reporting problems, for when validation is
      # skipped (export, assets:precompile).
      def load_files_leniently
        load_files(@klass.docuconf_declaration)
        nil
      rescue StandardError
        nil
      end

      def load_files(decl)
        violations = []
        decl.files.each do |file|
          value, failures = Files.load(file, env: @env, password: keystore_password(decl, file), now: @now)
          @config.docuconf_files[file.accessor] = value
          failures.each do |f|
            violations << Violation.new(input: file.name, kind: :file, code: f.code, message: f.message)
          end
        end
        violations
      end

      private

      # Says where the value can come from.
      def missing_message(var)
        return "required, and not set: set #{var.name} in the environment (a secret cannot come from a file)" if var.secret

        where = "#{var.attr} in #{yaml_name}"
        where += " or the overlay #{@klass.docuconf_declaration.overlays.map(&:name).join(", ")}" unless @klass.docuconf_declaration.overlays.empty?
        "required, and not set: set #{var.name} in the environment, or #{where}"
      end

      def yaml_name
        path = ::Anyway::Settings.default_config_path.call(@klass.config_name).to_s
        root = ::Anyway::Settings.app_root.to_s
        path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
      rescue StandardError
        "config/#{@klass.config_name}.yml"
      end

      def required?(var)
        @klass.required_attributes.include?(var.attr)
      end

      def overridden?(attr)
        o = @config.instance_variable_get(:@docuconf_overrides)
        o.respond_to?(:key?) && (o.key?(attr) || o.key?(attr.to_s))
      end

      def keystore_password(decl, file)
        pv = file[:password_var]
        return nil unless file.type == "keystore" && pv

        var = pv.is_a?(Symbol) ? decl.var(pv) : decl.vars.find { |v| v.name == pv.to_s }
        value = var ? @config.public_send(var.attr) : @env[pv.to_s]
        value&.to_s
      end
    end
  end
end
