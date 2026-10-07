# frozen_string_literal: true

# Every variable type and every file type, for the export golden test and
# the boot validation tests.
module Fixtures
  S = Docuconf::Anyway::Schema

  class GatewayConfig < Anyway::Config
    include Docuconf::Anyway

    config_name :gateway

    attr_config :database_url, :public_url, :region, :allowed_origins, :worker_ports, :rate_limits,
      :keystore_password, :gomemlimit, :secret_key_base,
      port: 8080, sample_rate: 0.25, debug: false, request_timeout: "PT30S", log_level: "info"

    required :database_url, :public_url, :region, :allowed_origins

    coerce_types port: :integer, gomemlimit: :integer, sample_rate: :float, debug: :boolean,
      request_timeout: :duration, rate_limits: :json,
      allowed_origins: {type: :string, array: true}, worker_ports: {type: :integer, array: true}

    describe :database_url, "Primary Postgres connection string", type: :url, schemes: %w[postgres postgresql]
    describe :public_url, "Externally visible base URL", type: :url, schemes: %w[https]
    describe :port, "HTTP listen port", min: 1, max: 65_535
    describe :gomemlimit, "Soft memory limit, in bytes", min: 1
    describe :sample_rate, "Fraction of requests traced", min: 0, max: 1
    describe :debug, "Verbose request logging"
    describe :request_timeout, "Upstream request timeout", min: "1s", max: "5m"
    describe :log_level, "Minimum log level emitted", values: %w[debug info warn error], group: "logging"
    describe :allowed_origins, "CORS origins allowed to call the API", min_items: 1, max_items: 10
    describe :worker_ports, "Ports the workers bind", item_min: 1, item_max: 65_535
    describe :rate_limits, "Default per-client rate limits",
      schema: {perMinute: S.integer(min: 1), "burst?": S.integer(min: 0)}
    describe :region, "Cloud region the service runs in", examples: ["eu-west-1"]
    constrain :region, pattern: "^[a-z]{2}-[a-z]+-[0-9]$", min_length: 4, max_length: 32
    describe :keystore_password, "Password for the partner keystore", min_length: 1
    secret :database_url, :keystore_password

    # Comes from Rails credentials, which the platform does not inject.
    exclude :secret_key_base

    # The platform may supply non-secret settings in this file, nested by
    # configKey (gateway: {port: 9090}).
    config_overlay :platform,
      path: "/etc/gateway/overlay/gateway.yml",
      description: "Settings the platform supplies as a mounted file",
      reload: :watch

    config_file :routes,
      format: :yaml,
      path: "/etc/gateway/routes/routes.yaml",
      path_env: "ROUTES_FILE",
      description: "Routing table: path prefixes and their upstreams",
      required: true,
      reload: :watch,
      max_size: 65_536,
      schema: {
        routes: S.array(
          {match: S.string(pattern: "^/"), upstream: S.string(pattern: "^https?://"), "timeout?": String},
          min_items: 1
        )
      }

    tls_file :serving_tls,
      path: "/etc/gateway/tls",
      description: "Certificate the gateway serves HTTPS with",
      required: true,
      reload: :watch,
      dns_names: %w[gateway.internal api.example.com],
      key_algorithms: %w[ECDSA RSA],
      min_remaining: "720h",
      require_ca: true

    ca_bundle_file :upstream_ca,
      path: "/etc/gateway/ca/bundle.pem",
      path_env: "SSL_CERT_FILE",
      description: "Private CAs the gateway trusts for upstream TLS"

    keystore_file :partner_keystore,
      path: "/etc/gateway/partner/keystore.p12",
      description: "Client certificate for mTLS to the partner API",
      password_var: :keystore_password

    text_file :license,
      path: "/etc/gateway/license/license.key",
      description: "Gateway licence key",
      required: true,
      pattern: "^[A-Z0-9]{5}(-[A-Z0-9]{5}){3}\\n?$"

    binary_file :geoip,
      path: "/data/geoip/GeoLite2-City.mmdb",
      description: "GeoIP database for country-based routing",
      max_size: 134_217_728
  end
end
