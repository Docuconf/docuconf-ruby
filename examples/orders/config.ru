# frozen_string_literal: true

require "json"
require_relative "config/orders_config"

# Loading the config validates it: every problem is reported at once, each
# with a stable code, and the secret's value is never printed.
begin
  CONFIG = OrdersConfig.new
rescue Docuconf::Anyway::ValidationError => e
  warn e.message
  exit 1
end

run lambda { |env|
  case [env["REQUEST_METHOD"], env["PATH_INFO"]]
  in ["GET", "/healthz"]
    [200, {"content-type" => "text/plain"}, ["ok"]]
  in ["GET", "/config"]
    body = {
      PORT: CONFIG.port,
      LOG_LEVEL: CONFIG.log_level,
      DATABASE_URL: "***", # secret in the contract
      ALLOWED_ORIGINS: CONFIG.allowed_origins,
      REQUEST_TIMEOUT: Docuconf::Anyway::Duration.format_go(Docuconf::Anyway::Duration.to_ns(CONFIG.request_timeout)),
      WORKER_COUNT: CONFIG.worker_count
    }
    [200, {"content-type" => "application/json"}, [JSON.generate(body)]]
  else
    [404, {"content-type" => "text/plain"}, ["not found"]]
  end
}
