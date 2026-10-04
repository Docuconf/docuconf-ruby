# frozen_string_literal: true

module Docuconf
  module Anyway
    # Class macros added to an Anyway::Config subclass by
    # `include Docuconf::Anyway`.
    module ClassMethods
      # Documents an attribute and optionally adds docuconf metadata:
      #
      #   describe :port, "HTTP listen port", min: 1, max: 65535, group: "http"
      #   describe :database_url, "Primary database", type: :url, schemes: %w[postgres]
      #
      # Options: type, group, examples, config_key, deprecated, secret, and
      # every constraint `constrain` takes.
      def describe(attr, description, **options)
        docuconf_merge_meta(attr, options.merge(description: description))
      end

      # Marks attributes as secret: values never appear in errors or the
      # contract, and the platform must supply them from a Secret.
      def secret(*attrs)
        attrs.each { |a| docuconf_merge_meta(a, {secret: true}) }
      end

      # Adds constraints the host library has no field for:
      #
      #   constrain :port, min: 1, max: 65535
      #   constrain :region, pattern: "^[a-z]{2}-[a-z]+-[0-9]$", min_length: 4
      #   constrain :log_level, values: %w[debug info warn error]
      #   constrain :origins, min_items: 1, max_items: 10
      #   constrain :callback_url, schemes: %w[https]
      #   constrain :rate_limits, schema: {per_minute: Integer, "burst?": Integer}
      def constrain(attr, **options)
        docuconf_merge_meta(attr, options)
      end

      # Leaves attributes out of the contract and of docuconf's checks:
      # values the platform does not inject, such as Rails credentials
      # (SPEC §4.4). anyway_config still loads them, and `required` still
      # applies to them.
      def exclude(*attrs)
        attrs.each { |a| docuconf_excluded << a.to_sym }
      end

      # A structured config file bound to a schema derived from a Ruby type
      # spec (see Docuconf::Anyway::Schema), or an explicit JSON Schema.
      #
      #   config_file :routes, format: :yaml, path: "/etc/gw/routes/routes.yaml",
      #     description: "Routing table", schema: {routes: [{match: String, upstream: String}]}
      #
      # `into:` binds the parsed data: a callable, or a class built with
      # keyword arguments (Struct with keyword_init, Data).
      def config_file(name, format:, schema: nil, json_schema: nil, into: nil, **common)
        docuconf_add_file(name, "config", common,
          format: format.to_s, schema_spec: schema, json_schema: json_schema, into: into)
      end

      # A kubernetes.io/tls directory: tls.crt, tls.key and, with
      # require_ca, ca.crt.
      def tls_file(name, dns_names: nil, key_algorithms: nil, min_remaining: nil, require_ca: false, **common)
        docuconf_add_file(name, "tls", common.merge(secret: true),
          dns_names: dns_names&.map(&:to_s), key_algorithms: key_algorithms&.map(&:to_s),
          min_remaining: min_remaining, require_ca: require_ca)
      end

      # A PEM bundle of CA certificates.
      def ca_bundle_file(name, min_certificates: nil, **common)
        docuconf_add_file(name, "caBundle", common, min_certificates: min_certificates)
      end

      # A PKCS#12 (or JKS) keystore; `password_var` names a secret attribute
      # of this class (a Symbol) or an environment variable (a String).
      def keystore_file(name, format: :pkcs12, password_var: nil, **common)
        docuconf_add_file(name, "keystore", common.merge(secret: true),
          format: format.to_s, password_var: password_var)
      end

      # A text file such as a licence key.
      def text_file(name, pattern: nil, min_length: nil, max_length: nil, **common)
        docuconf_add_file(name, "text", common, pattern: pattern, min_length: min_length, max_length: max_length)
      end

      # Opaque bytes, such as a GeoIP database. The accessor returns the
      # resolved path.
      def binary_file(name, **common)
        docuconf_add_file(name, "binary", common)
      end

      # The checked declaration (variables and files) of this class.
      def docuconf_declaration
        @docuconf_declaration ||= Declaration.build(self).tap do |d|
          d.warnings.each { |w| Docuconf::Anyway.warn(w) }
          docuconf_install_coercions(d)
        end
      end

      # Forgets the cached declaration (after macros are called again).
      def docuconf_reset!
        @docuconf_declaration = nil
      end

      def docuconf_var_meta
        @docuconf_var_meta ||= superclass.respond_to?(:docuconf_var_meta) ? superclass.docuconf_var_meta.transform_values(&:dup) : {}
      end

      def docuconf_excluded
        @docuconf_excluded ||= superclass.respond_to?(:docuconf_excluded) ? superclass.docuconf_excluded.dup : []
      end

      def docuconf_file_decls
        @docuconf_file_decls ||= superclass.respond_to?(:docuconf_file_decls) ? superclass.docuconf_file_decls.dup : {}
      end

      # anyway_config memoizes its type caster on first load; build the
      # declaration first, so docuconf's coercions are part of it.
      def type_caster(val = nil)
        docuconf_declaration if val.nil? && !@docuconf_installing
        super
      end

      private

      def docuconf_merge_meta(attr, options)
        unknown = options.keys - VAR_OPTIONS - [:description]
        raise ArgumentError, "unknown docuconf option(s) for #{attr}: #{unknown.join(", ")}" unless unknown.empty?

        @docuconf_declaration = nil
        (docuconf_var_meta[attr.to_sym] ||= {}).merge!(options)
      end

      FILE_COMMON = %i[path description required path_env reload max_size group deprecated secret name].freeze
      private_constant :FILE_COMMON

      def docuconf_add_file(accessor, type, common, **options)
        accessor = accessor.to_sym
        unknown = common.keys - FILE_COMMON
        raise ArgumentError, "unknown option(s) for file #{accessor}: #{unknown.join(", ")}" unless unknown.empty?
        raise ArgumentError, "file #{accessor}: path: is required" unless common[:path]
        raise ArgumentError, "file #{accessor}: description: is required" unless common[:description]
        if config_attributes.include?(accessor)
          raise ArgumentError, "file #{accessor}: name clashes with attr_config :#{accessor}"
        end

        problems = []
        if type == "config"
          options[:schema] = Declaration.schema_from(
            {schema: options.delete(:schema_spec), json_schema: options.delete(:json_schema)}, problems, "file #{accessor}"
          )
        end
        if type == "tls" && options[:min_remaining]
          ns = Duration.to_ns(options[:min_remaining])
          if ns.nil? || ns.negative?
            problems << "file #{accessor}: min_remaining #{options[:min_remaining].inspect} is not a duration"
          else
            options[:min_remaining] = Duration.format_go(ns)
          end
        end
        raise DeclarationError, problems unless problems.empty?

        decl = FileDecl.new(
          accessor: accessor,
          name: (common[:name] || accessor.to_s.tr("_", "-")).to_s,
          type: type,
          description: common[:description].to_s,
          required: common[:required] == true,
          secret: common[:secret] == true,
          path: common[:path].to_s,
          path_env: common[:path_env]&.to_s,
          reload: (common[:reload] || :restart).to_s,
          max_size: common[:max_size],
          group: common[:group]&.to_s,
          deprecated: Declaration.normalize_deprecated(common[:deprecated]),
          options: options
        )
        @docuconf_declaration = nil
        docuconf_file_decls[accessor] = decl
        define_method(accessor) { docuconf_files[accessor] }
        decl
      end

      def docuconf_install_coercions(decl)
        missing = decl.vars.reject { |v| coercion_mapping.key?(v.attr) }
        return if missing.empty?

        @docuconf_installing = true
        coerce_types(missing.to_h { |v| [v.attr, v.coercion] })
        @type_caster = nil
      ensure
        @docuconf_installing = false
      end
    end
  end
end
