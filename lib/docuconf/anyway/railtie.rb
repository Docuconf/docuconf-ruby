# frozen_string_literal: true

module Docuconf
  module Anyway
    # Validates every docuconf config class once the app has booted, so a
    # misconfigured pod fails at start with every problem listed (and in
    # /dev/termination-log). Validation is skipped for build-time tasks:
    # assets:precompile (anyway_config's SECRET_KEY_BASE_DUMMY handling),
    # docuconf:export, and DOCUCONF_SKIP_VALIDATION=1.
    #
    #   config.docuconf.validate_on_boot = false   # opt out
    class Railtie < ::Rails::Railtie
      BUILD_TASKS = /\A(?:assets:|docuconf:|javascript:|css:|tailwindcss:)/

      config.docuconf = ActiveSupport::OrderedOptions.new
      config.docuconf.validate_on_boot = true

      rake_tasks do
        load File.expand_path("tasks.rake", __dir__)
      end

      config.after_initialize do |app|
        next unless app.config.docuconf.validate_on_boot
        next if Docuconf::Anyway.skip_validation? || Railtie.build_task?

        Railtie.eager_load_configs
        Docuconf::Anyway.validate_all!
      end

      def self.build_task?
        return false unless defined?(::Rake) && ::Rake.respond_to?(:application)

        ::Rake.application.top_level_tasks.any? { |t| BUILD_TASKS.match?(t) }
      rescue StandardError
        false
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
