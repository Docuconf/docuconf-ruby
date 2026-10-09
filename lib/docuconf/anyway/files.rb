# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "openssl"

module Docuconf
  module Anyway
    # Boot-time checks for file inputs (SPEC §11.2 item 7). Each check
    # returns [value, failures]; the value is nil when a check failed or an
    # optional input is absent.
    module Files
      Failure = Values::Failure
      BOM = "﻿"
      UNREADABLE_HINT = "permission denied; a secret volume is mounted 0400 and owned by root, so a non-root " \
        "container needs the pod's fsGroup set"

      module_function

      # The path a file input is read from: the pathEnv variable when set,
      # else the declared path, under DOCUCONF_FILE_ROOT when that is set.
      def resolve_path(file, env = ENV)
        path = file.path
        if file.path_env
          from_env = env[file.path_env]
          path = from_env unless from_env.nil? || from_env.empty?
        end
        root = env["DOCUCONF_FILE_ROOT"]
        if root && !root.empty? && path.start_with?("/")
          File.join(root, path)
        else
          path
        end
      end

      # Loads and checks one file input. `password` is the keystore password
      # (or nil when its variable is unset).
      def load(file, env: ENV, password: nil, now: Time.now)
        path = resolve_path(file, env)
        if file.type == "tls"
          load_tls(file, path, now)
        else
          content, failures = read(path, file.max_size)
          return [nil, []] if content == :missing && !file.required
          return [nil, [Failure.new(:file_missing, "#{path} does not exist")]] if content == :missing
          return [nil, failures] unless failures.empty?

          case file.type
          when "config" then load_config(file, content)
          when "caBundle" then load_ca_bundle(file, content)
          when "keystore" then load_keystore(file, content, password)
          when "text" then load_text(file, content)
          when "binary" then [path, []]
          end
        end
      end

      # Returns [bytes, failures], or [:missing, []].
      def read(path, max_size)
        st = File.stat(path)
        return [nil, [Failure.new(:file_malformed, "#{path} is a directory, not a file")]] if st.directory?
        if max_size && st.size > max_size
          return [nil, [Failure.new(:file_too_large, "#{path} is #{st.size} bytes, more than max_size #{max_size}")]]
        end

        [File.binread(path), []]
      rescue Errno::ENOENT, Errno::ENOTDIR
        [:missing, []]
      rescue Errno::EACCES
        [nil, [Failure.new(:file_unreadable, "#{path}: #{UNREADABLE_HINT}")]]
      rescue SystemCallError, IOError => e
        [nil, [Failure.new(:file_unreadable, "#{path}: #{e.class.name.split("::").last}")]]
      end

      def utf8(content)
        s = content.dup.force_encoding(Encoding::UTF_8)
        s.valid_encoding? ? s : nil
      end

      def load_config(file, content)
        text = utf8(content)
        return [nil, [Failure.new(:file_malformed, "not valid UTF-8")]] unless text

        text = text.delete_prefix(BOM)
        data = begin
          parse_config(file[:format], text)
        rescue JSON::ParserError, Psych::Exception, ConfigParseError => e
          detail = file.secret ? "" : ": #{e.message.lines.first.to_s.strip}"
          return [nil, [Failure.new(:file_malformed, "cannot parse as #{file[:format]}#{detail}")]]
        end

        if file[:schema]
          errors = Schema.validate(file[:schema], data)
          unless errors.empty?
            detail = file.secret ? "#{errors.size} error(s)" : errors.first(5).join("; ")
            return [nil, [Failure.new(:schema_mismatch, "does not match its schema: #{detail}")]]
          end
        end

        bind(file, data)
      end

      class ConfigParseError < StandardError; end

      def parse_config(format, text)
        case format
        when "json" then JSON.parse(text)
        when "yaml"
          YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true)
        when "toml"
          begin
            require "tomlrb"
          rescue LoadError
            raise ConfigParseError, "TOML support needs the tomlrb gem"
          end
          begin
            Tomlrb.parse(text)
          rescue StandardError => e
            raise ConfigParseError, e.message
          end
        end
      end

      def bind(file, data)
        into = file[:into]
        return [deep_freeze(data), []] unless into

        value =
          if into.respond_to?(:call)
            into.call(data)
          elsif data.is_a?(Hash)
            into.new(**data.transform_keys(&:to_sym))
          else
            into.new(data)
          end
        [value, []]
      rescue ArgumentError, TypeError, KeyError, NoMethodError => e
        [nil, [Failure.new(:schema_mismatch, "does not bind to #{into}: #{e.message}")]]
      end

      def deep_freeze(obj)
        case obj
        when Hash then obj.each_value { |v| deep_freeze(v) }
        when Array then obj.each { |v| deep_freeze(v) }
        end
        obj.freeze
      end

      def load_tls(file, dir, now)
        unless File.directory?(dir)
          return [nil, []] unless file.required || File.exist?(dir)

          return [nil, [Failure.new(:file_missing, "#{dir} is not a directory holding tls.crt and tls.key")]]
        end

        parts = {}
        failures = []
        {"tls.crt" => :cert, "tls.key" => :key, "ca.crt" => :ca}.each do |fname, k|
          content, f = read(File.join(dir, fname), file.max_size)
          if content == :missing
            failures << Failure.new(:file_missing, "#{fname} is missing from #{dir}") unless k == :ca
          elsif content
            parts[k] = content
          end
          failures.concat(f)
        end
        return [nil, failures] unless failures.empty?

        TLS.check(
          cert_pem: parts[:cert], key_pem: parts[:key], ca_pem: parts[:ca],
          dns_names: file[:dns_names], key_algorithms: file[:key_algorithms],
          min_remaining: file[:min_remaining], require_ca: file[:require_ca], now: now
        )
      end

      def load_ca_bundle(file, content)
        min = file[:min_certificates] || 1
        certs, failures = TLS.parse_certificates(content, "bundle", failure_code: :file_malformed)
        return [nil, failures] unless certs

        if certs.size < min
          return [nil, [Failure.new(:file_malformed, "holds #{certs.size} certificate(s), needs at least #{min}")]]
        end

        [CABundle.new(content, certs), []]
      end

      JKS_MAGIC = ["feedfeed", "cececece"].freeze

      def load_keystore(file, content, password)
        if file[:format] == "jks"
          # Ruby has no JKS parser: only the magic number can be checked.
          magic = content.byteslice(0, 4).unpack1("H*")
          return [content, []] if JKS_MAGIC.include?(magic)

          return [nil, [Failure.new(:keystore_unreadable, "not a JKS keystore")]]
        end

        # An unset password variable is the empty password (SPEC §11.2 item 7).
        [OpenSSL::PKCS12.new(content, password.to_s), []]
      rescue OpenSSL::PKCS12::PKCS12Error
        [nil, [Failure.new(:keystore_unreadable, "cannot open the PKCS#12 keystore with the password from its password variable")]]
      end

      def load_text(file, content)
        text = utf8(content)
        return [nil, [Failure.new(:file_malformed, "not valid UTF-8 text")]] unless text

        failures = []
        len = text.length
        if file[:min_length] && len < file[:min_length]
          failures << Failure.new(:out_of_range, "is #{len} characters, shorter than #{file[:min_length]}")
        end
        if file[:max_length] && len > file[:max_length]
          failures << Failure.new(:out_of_range, "is #{len} characters, longer than #{file[:max_length]}")
        end
        if file[:pattern] && !RE2.compile(file[:pattern]).match?(text)
          failures << Failure.new(:pattern_mismatch, "does not match pattern #{file[:pattern]}")
        end
        failures.empty? ? [text.freeze, []] : [nil, failures]
      end
    end
  end
end
