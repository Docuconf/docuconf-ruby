# frozen_string_literal: true

require "docuconf/anyway"

class OrdersConfig < Anyway::Config
  include Docuconf::Anyway

  # Read PORT, DATABASE_URL, ... with no ORDERS_ prefix.
  env_prefix ""

  attr_config :database_url, :webhook_keys,
    port: 8080, log_level: "info", allowed_origins: ["http://localhost:3000"],
    request_timeout: "30s", worker_count: 4
  required :database_url

  describe :port, "HTTP listen port", min: 1, max: 65_535
  describe :log_level, "Minimum log level", values: %w[debug info warn error]
  describe :database_url, "Postgres connection string for orders", type: :url, schemes: %w[postgres],
    max_length: 2048, secret: true # never printed, and the contract marks it secret
  describe :allowed_origins, "CORS origins allowed to call the API", min_items: 1

  # How long the server works on one request before it gives up.
  #
  # Raise it when clients upload large order batches. Keep it below the load
  # balancer's idle timeout, or the client sees a reset rather than a +504+.
  describe :request_timeout, "Time allowed to handle one request", min: "1s", max: "5m"
  describe :worker_count, "Background workers processing orders", min: 1, max: 64

  # A webhook is accepted when it is signed with any key in the set. Each key
  # is 32 to 256 characters, so an empty or truncated key fails at boot.
  # Without this variable, the service rejects every webhook.
  describe :webhook_keys, "Keys that verify the signature on incoming payment webhooks", type: :key_set,
    key_min_length: 32, key_max_length: 256
end
