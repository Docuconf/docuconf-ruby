# frozen_string_literal: true

require "rails/generators"

module Docuconf
  module Generators
    # rails g docuconf:config NAME [param ...]
    #
    # Adds docuconf to config/configs/NAME_config.rb: `include
    # Docuconf::Anyway` and a `describe` stub for every attribute that has
    # none. Creates the class (as `rails g anyway:config` would) when the
    # file does not exist. The stubs have empty descriptions, so the app
    # refuses to boot until each one is filled in.
    class ConfigGenerator < ::Rails::Generators::NamedBase
      argument :parameters, type: :array, default: [], banner: "param1 param2"
      class_option :app, type: :boolean, default: false, desc: "Use app/configs instead of config/configs"

      def create_or_update_config
        path = File.join(config_root, class_path, "#{file_name}_config.rb")
        unless File.exist?(File.join(destination_root, path))
          create_file path, <<~RUBY
            # frozen_string_literal: true

            class #{class_name}Config < #{base_class}
              include Docuconf::Anyway

              attr_config #{parameters.empty? ? ":setting" : parameters.map { |p| ":#{p}" }.join(", ")}
            end
          RUBY
        end

        source = File.read(File.join(destination_root, path))
        unless source.include?("include Docuconf::Anyway")
          inject_into_file path, "  include Docuconf::Anyway\n\n", after: /^\s*class .*Config\b.*\n/
          source = File.read(File.join(destination_root, path))
        end

        described = source.scan(/^\s*describe\s+:(\w+)/).flatten
        missing = attributes.map(&:to_s) - described
        return if missing.empty?

        stubs = missing.map { |a| "  describe :#{a}, \"\" # TODO: what is #{a} for? (at least 5 characters)\n" }.join
        inject_into_file path, "\n#{stubs}", before: /^end\s*\z/
      end

      private

      # The class's attributes when it loads, else the ones given.
      def attributes
        klass = "#{class_name}Config".safe_constantize
        attrs = klass.respond_to?(:config_attributes) ? klass.config_attributes : []
        attrs = parameters if attrs.empty?
        attrs.map(&:to_s).uniq
      end

      def base_class
        root = ::Rails.root.join(static_config_root, "application_config.rb")
        root.exist? ? "ApplicationConfig" : "Anyway::Config"
      end

      def static_config_root
        ::Anyway::Settings.autoload_static_config_path || "config/configs"
      end

      def config_root
        options[:app] ? "app/configs" : static_config_root.to_s.delete_prefix("#{::Rails.root}/")
      end
    end
  end
end
