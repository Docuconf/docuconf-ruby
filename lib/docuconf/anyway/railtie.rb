# frozen_string_literal: true

module Docuconf
  module Anyway
    # Validates every docuconf config class once the app has booted, so a
    # misconfigured pod fails at start with every problem listed (and in
    # /dev/termination-log), without a backtrace.
    #
    # - Build-time tasks skip validation: assets:precompile (anyway_config's
    #   SECRET_KEY_BASE_DUMMY handling), docuconf:*, and
    #   DOCUCONF_SKIP_VALIDATION=1.
    # - Tooling commands (console, generate, destroy, routes, notes,
    #   credentials, db:*) print the problems as a warning and carry on.
    # - Everything else (server, runner, jobs, tests) exits 1.
    #
    #   config.docuconf.validate_on_boot = false     # opt out
    #   config.docuconf.raise_on_boot = true         # raise ValidationError instead of exiting
    #   config.docuconf.default_profile = "production"  # RAILS_ENV default in the exported contract
    #   config.docuconf.export_profiles = %w[production staging]  # YAML sections to export
    #
    # Secret attributes are added to config.filter_parameters, so request
    # logs and error reports filter them as Rails filters passwords.
    class Railtie < ::Rails::Railtie
      BUILD_TASKS = /\A(?:assets:|docuconf:|javascript:|css:|tailwindcss:)/
      TOOLING_TASKS = /\A(?:db:|routes|notes|credentials:|secrets:|stats|about|log:|tmp:|time:|zeitwerk:|test:prepare)/
      TOOLING_COMMANDS = %w[ConsoleCommand GenerateCommand DestroyCommand RoutesCommand NotesCommand
        CredentialsCommand EncryptedCommand DbconsoleCommand].freeze

      config.docuconf = ActiveSupport::OrderedOptions.new
      config.docuconf.validate_on_boot = true
      config.docuconf.raise_on_boot = false
      config.docuconf.default_profile = nil
      config.docuconf.export_profiles = nil

      rake_tasks do
        load File.expand_path("tasks.rake", __dir__)
      end

      generators do
        require_relative "generators/config_generator"
      end

      initializer "docuconf.filter_parameters" do |app|
        app.config.filter_parameters << Docuconf::Anyway.method(:filter_secret_parameter).to_proc
      end

      config.after_initialize do |app|
        next unless app.config.docuconf.validate_on_boot
        next if Docuconf::Anyway.skip_validation? || Railtie.build_task?

        Railtie.eager_load_configs
        begin
          Docuconf::Anyway.validate_all!
        rescue ValidationError, DeclarationError => e
          raise if app.config.docuconf.raise_on_boot

          if Railtie.tooling_command?
            Kernel.warn("#{e.message}\ndocuconf: continuing, since this is a tooling command; the app itself " \
              "would not start")
          else
            Docuconf::Anyway.write_termination_log(e.message) if e.is_a?(DeclarationError)
            Kernel.warn(e.message)
            exit 1
          end
        end
      end

      def self.build_task?
        top_level_tasks.any? { |t| BUILD_TASKS.match?(t) }
      end

      # rails console, generate, routes, db:migrate and friends: problems
      # are warnings, so a developer can still inspect and fix the app.
      def self.tooling_command?
        return true if defined?(::Rails::Console) || defined?(::Rails::Generators::Base)
        return true if top_level_tasks.any? { |t| TOOLING_TASKS.match?(t) }

        commands = defined?(::Rails::Command) ? ::Rails::Command : nil
        commands && TOOLING_COMMANDS.any? { |c| commands.const_defined?(c, false) } ? true : false
      end

      def self.top_level_tasks
        return [] unless defined?(::Rake) && ::Rake.respond_to?(:application)

        ::Rake.application.top_level_tasks
      rescue StandardError
        []
      end

      # Config classes are autoloaded; load them so every one is validated
      # and exported.
      def self.eager_load_configs
        ::Anyway::Settings.autoloader&.eager_load
        main = ::Rails.autoloaders.main if ::Rails.respond_to?(:autoloaders)
        %w[app/configs config/configs].each do |dir|
          path = ::Rails.root.join(dir)
          next unless path.directory?

          if main.respond_to?(:eager_load_dir)
            begin
              main.eager_load_dir(path.to_s)
            rescue StandardError
              nil
            end
          end
        end
      end
    end
  end
end
