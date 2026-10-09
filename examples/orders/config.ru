# frozen_string_literal: true

require "json"
require_relative "config/orders_config"
require_relative "webhook"

# Loading the config validates it: every problem is reported at once, each
# with a stable code, and the secret's value is never printed. On failure
# load! prints the problems and exits 1.
CONFIG = OrdersConfig.load!

run lambda { |env|
  case [env["REQUEST_METHOD"], env["PATH_INFO"]]
  in ["GET", "/healthz"]
    [200, {"content-type" => "text/plain"}, ["ok"]]
  in ["GET", "/config"]
    body = {
      PORT: CONFIG.port,
      LOG_LEVEL: CONFIG.log_level,
      DATABASE_URL: "***", # secrets in the contract, never shown, set or not
      ALLOWED_ORIGINS: CONFIG.allowed_origins,
      REQUEST_TIMEOUT: Docuconf::Anyway.format_duration(CONFIG.request_timeout),
      WORKER_COUNT: CONFIG.worker_count,
      WEBHOOK_KEYS: "***"
    }
    [200, {"content-type" => "application/json"}, [JSON.generate(body)]]
  in ["POST", "/webhooks/payments"]
    # Payment webhooks, signed with any key in WEBHOOK_KEYS (see
    # config/orders_config.rb for how to rotate it).
    body = env["rack.input"].read(1 << 20).to_s
    if Webhook.verify(CONFIG.webhook_keys, body, env["HTTP_X_SIGNATURE"])
      [204, {}, []]
    else
      [401, {"content-type" => "text/plain"}, ["bad signature"]]
    end
  else
    [404, {"content-type" => "text/plain"}, ["not found"]]
  end
}
