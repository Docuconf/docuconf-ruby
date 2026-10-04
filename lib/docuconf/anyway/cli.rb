# frozen_string_literal: true

require "optparse"

module Docuconf
  module Anyway
    # `docuconf export` and `docuconf check` for apps without Rails (in Rails,
    # use `rails docuconf:export`).
    class CLI
      USAGE = <<~TXT
        Usage:
          docuconf export -n NAME [options] FILE...   write the contract for the config classes FILE defines
          docuconf check [options] FILE...            validate the current environment and files

        FILE is a Ruby file to require (for example config/configs/billing_config.rb).
      TXT

      def self.start(argv, out: $stdout, err: $stderr)
        new(out: out, err: err).run(argv)
      end

      def initialize(out:, err:)
        @out = out
        @err = err
      end

      def run(argv)
        argv = argv.dup
        command = argv.shift
        case command
        when "export" then export(argv)
        when "check" then check(argv)
        when "-h", "--help", "help", nil
          @out.puts USAGE
          command.nil? ? 2 : 0
        when "-v", "--version"
          @out.puts VERSION
          0
        else
          @err.puts "docuconf: unknown command #{command.inspect}\n\n#{USAGE}"
          2
        end
      rescue OptionParser::ParseError => e
        @err.puts "docuconf: #{e.message}"
        2
      rescue DeclarationError => e
        @err.puts e.message
        1
      end

      private

      def common(opts, o)
        opts.on("-r", "--require FILE", "Ruby file to require (repeatable)") { |f| (o[:require] ||= []) << f }
        opts.on("-I", "--include DIR", "Add DIR to $LOAD_PATH (repeatable)") { |d| $LOAD_PATH.unshift(File.expand_path(d)) }
        opts.on("-c", "--class NAME", "Config class to use (repeatable; default: every loaded docuconf class)") do |c|
          (o[:classes] ||= []) << c
        end
      end

      def load_files(o, files)
        (Array(o[:require]) + files).each { |f| require File.expand_path(f) }
        return nil unless o[:classes]

        o[:classes].map do |n|
          Object.const_get(n)
        rescue NameError
          raise OptionParser::InvalidArgument, "class #{n} is not defined"
        end
      end

      def export(argv)
        o = {profiles: true}
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: docuconf export -n NAME [options] FILE..."
          opts.on("-n", "--name NAME", "Service name, a DNS label (required)") { |v| o[:name] = v }
          opts.on("-o", "--out FILE", "Write to FILE instead of stdout") { |v| o[:out] = v }
          opts.on("--app-version VERSION", "metadata.appVersion, e.g. the git SHA") { |v| o[:app_version] = v }
          opts.on("--package NAME", "CUE package name (default: the name with - as _)") { |v| o[:package] = v }
          opts.on("--root DIR", "Directory config/<name>.yml is read from (default: .)") { |v| o[:root] = v }
          opts.on("--[no-]profiles", "Export values from config/<name>.yml (default: yes)") { |v| o[:profiles] = v }
          opts.on("--selector VAR", "Variable that selects the YAML section (default: RAILS_ENV)") { |v| o[:selector] = v }
          opts.on("--default-profile NAME", "Section used when the selector is unset (default: development)") do |v|
            o[:default_profile] = v
          end
          common(opts, o)
        end
        files = parser.parse(argv)
        raise OptionParser::MissingArgument, "--name" unless o[:name]

        Docuconf::Anyway.export_mode = true
        classes = load_files(o, files)
        options = {name: o[:name], classes: classes, app_version: o[:app_version], root: o[:root],
                   profiles: o[:profiles], package: o[:package]}
        options[:selector] = o[:selector] if o[:selector]
        options[:default_profile] = o[:default_profile] if o[:default_profile]
        text = Docuconf::Anyway.export(**options)
        if o[:out]
          File.write(o[:out], text)
          @err.puts "docuconf: wrote #{o[:out]}"
        else
          @out.print text
        end
        0
      end

      def check(argv)
        o = {}
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: docuconf check [options] FILE..."
          common(opts, o)
        end
        files = parser.parse(argv)
        Docuconf::Anyway.watch_files = false
        classes = load_files(o, files)
        Docuconf::Anyway.validate_all!(classes)
        @out.puts "docuconf: configuration is valid"
        0
      rescue ValidationError => e
        @err.puts e.message
        1
      end
    end
  end
end
