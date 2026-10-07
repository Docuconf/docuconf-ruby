# frozen_string_literal: true

require "docuconf/anyway"

class OrdersConfig < Anyway::Config
  include Docuconf::Anyway

  # Read PORT, DATABASE_URL, ... with no ORDERS_ prefix.
  env_prefix ""

  attr_config :database_url,
    port: 8080, log_level: "info", allowed_origins: ["http://localhost:3000"],
    request_timeout: "PT30S", worker_count: 4
  required :database_url
  coerce_types port: :integer, worker_count: :integer, request_timeout: :duration,
    allowed_origins: {type: :string, array: true}

  describe :port, "HTTP listen port", min: 1, max: 65_535
  describe :log_level, "Minimum log level", values: %w[debug info warn error]
  describe :database_url, "Postgres connection string for orders", type: :url, schemes: %w[postgres]
  describe :allowed_origins, "CORS origins allowed to call the API", min_items: 1
  describe :request_timeout, "Time allowed to handle one request", min: "1s", max: "5m"
  describe :worker_count, "Background workers processing orders", min: 1, max: 64
  # The value is never printed, and the contract marks it secret.
  secret :database_url
end
