# frozen_string_literal: true

# The shared export fixture (docuconf-go conformance/export/fixture.yaml,
# SPEC §11.2 item 3), declared with this SDK's API. spec/export_fixture_spec.rb
# exports it and compares it with conformance/export/golden.cue using
# `docuconf conformance export`.
module Fixtures
  class ExportFixture < Anyway::Config
    include Docuconf::Anyway

    S = Docuconf::Anyway::Schema
    SETTINGS = {name: S.string(min_length: 1), replicas: S.integer(min: 1), "tags?": [String]}.freeze

    config_name :fixture
    env_prefix ""

    attr_config :database_url, :allowed_origins, :shards, :webhook_keys, :old_port, :partner_password,
      app_name: "orders", port: 8080, trace_ratio: 0.25, debug: false, request_timeout: "1m30s",
      log_level: "info", rate_limits: {"perMinute" => 60}
    required :database_url

    # The fixture gives a configKey to APP_NAME only; the others leave it
    # out, which config_key: false does (anyway_config's own key path,
    # fixture.<attr>, is the default).

    # Lower case, as a DNS label allows.
    describe :app_name, "Service name, used in logs and metrics", min_length: 2, max_length: 40,
      pattern: "^[a-z][a-z0-9-]*$", group: "general", examples: %w[orders billing], config_key: "App:Name"
    describe :database_url, "Primary Postgres connection string", type: :url, schemes: %w[postgres postgresql],
      max_length: 2048, group: "database", secret: true, config_key: false
    describe :port, "HTTP listen port", min: 1, max: 65_535, config_key: false
    describe :trace_ratio, "Fraction of requests traced", min: 0, max: 1, config_key: false
    describe :debug, "Serve the debug endpoints", config_key: false
    describe :request_timeout, "Upstream request timeout", type: :duration, min: "1s", max: "5m", config_key: false
    describe :log_level, "Minimum log level", values: %w[debug info warn error], config_key: false
    describe :allowed_origins, "CORS origins allowed to call the API", type: :list, items: :string,
      min_items: 1, max_items: 5, item_min_length: 1, item_max_length: 255, separator: ";", config_key: false
    describe :shards, "Shards this instance owns", type: :list, items: :int, item_min: 0, item_max: 1023,
      config_key: false
    describe :webhook_keys, "Keys that verify webhook signatures", type: :key_set,
      key_min_length: 32, key_max_length: 256, config_key: false
    describe :rate_limits, "Per-client rate limits", type: :json, max_length: 1024,
      schema: {perMinute: S.integer(min: 1), "burst?": S.integer(min: 0)}, config_key: false
    describe :old_port, "Port the service used to listen on", type: :int,
      deprecated: {message: "Use PORT instead", replaced_by: "PORT"}, config_key: false
    describe :partner_password, "Password of the partner keystore", secret: true, config_key: false

    config_file :settings, format: :json, path: "/etc/app/settings/settings.json", path_env: "SETTINGS_FILE",
      description: "Application settings", required: true, reload: :watch, max_size: 65_536, group: "general",
      schema: SETTINGS
    config_file :rules, format: :yaml, path: "/etc/app/rules/rules.yaml", description: "Routing rules",
      schema: SETTINGS
    config_file :flags, format: :toml, path: "/etc/app/flags/flags.toml", description: "Feature defaults",
      schema: SETTINGS
    tls_file :serving_tls, path: "/etc/app/tls", description: "Certificate the service serves HTTPS with",
      reload: :watch, dns_names: %w[app.example.test api.example.test], key_algorithms: %w[ECDSA Ed25519],
      min_remaining: "720h", require_ca: true
    ca_bundle_file :trust, path: "/etc/app/trust/bundle.pem", description: "CAs the service trusts",
      min_certificates: 2
    keystore_file :partner, path: "/etc/app/partner/keystore.p12",
      description: "Client certificate for the partner API", password_var: :partner_password
    text_file :licence, path: "/etc/app/licence/licence.key", description: "Licence key",
      min_length: 8, max_length: 64, pattern: "^[A-Z0-9-]+\\n?$"
    binary_file :geoip, path: "/data/geoip/geoip.mmdb", description: "GeoIP database", max_size: 134_217_728,
      deprecated: {message: "Use geo-db instead", replaced_by: "geo-db"}
    binary_file :geo_db, path: "/data/geo-db/geo.mmdb", description: "City-level location database"
  end
end
