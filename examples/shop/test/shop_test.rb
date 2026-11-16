# frozen_string_literal: true

# The shop's test matrix: roles, requiredIf and the otel@1 fragment, each
# case from the base env with a fresh, empty file root.
# Run with: bundle exec ruby test/shop_test.rb
require "bundler/setup"
require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../shop"

class ShopTest < Minitest::Test
  SECRET = "postgres://shop@db:5432/shop"
  BASE = {"DATABASE_URL" => SECRET}.freeze
  KEY_PATH = "etc/shop/webhooks/signing.key" # the file input's path, under the root
  WORKER_HOOKS = {"DOCUCONF_ROLE" => "worker", "QUEUES" => "default", "WEBHOOKS_ENABLED" => "true"}.freeze
  JSON_LOGS = {"DOCUCONF_ROLE" => "worker", "QUEUES" => "default", "LOG_FORMAT" => "json"}.freeze

  def setup
    @root = Dir.mktmpdir("shop-root")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def env(vars) = BASE.merge("DOCUCONF_FILE_ROOT" => @root).merge(vars)

  # Runs the shop as its entrypoint does: [exit status, stdout, stderr].
  def run_shop(vars)
    out = StringIO.new
    err = StringIO.new
    status = 0
    begin
      Shop.main(env(vars), out: out, err: err)
    rescue SystemExit => e
      status = e.status
    end
    [status, out.string, err.string]
  end

  def assert_ok(vars, line)
    status, out, err = run_shop(vars)
    assert_equal [0, "#{line}\n", ""], [status, out, err]
  end

  # Fails with exactly these [input, code] problems; returns the violations.
  def assert_problems(vars, want)
    error = assert_raises(Docuconf::Anyway::ValidationError) { Shop.load(env(vars), termination_log: false) }
    assert_equal want, error.violations.map { |v| [v.input, v.code.to_s] }
    status, out, err = run_shop(vars)
    assert_equal [1, ""], [status, out]
    assert_equal "#{error.message}\n", err
    refute_includes err, SECRET
    error.violations
  end

  def message_for(violations, input) = violations.find { |v| v.input == input }.message

  def test_01_web
    assert_ok({"DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "https://shop.example"},
      "shop web: port 8080, origins https://shop.example")
  end

  def test_02_worker_needs_no_allowed_origins
    assert_ok({"DOCUCONF_ROLE" => "worker", "QUEUES" => "default,mail"}, "shop worker: queues default,mail, webhooks off")
  end

  def test_03_web_needs_allowed_origins
    assert_problems({"DOCUCONF_ROLE" => "web"}, [%w[ALLOWED_ORIGINS missing_required]])
  end

  def test_04_no_role
    assert_problems({"QUEUES" => "default"}, [%w[DOCUCONF_ROLE missing_required]])
  end

  def test_05_unknown_role
    assert_problems({"DOCUCONF_ROLE" => "cron"}, [%w[DOCUCONF_ROLE not_in_enum]])
  end

  def test_06_json_logs_need_a_schema_url
    violations = assert_problems(JSON_LOGS, [%w[LOG_SCHEMA_URL missing_required]])
    assert_includes message_for(violations, "LOG_SCHEMA_URL"), 'is required when LOG_FORMAT is "json"'
  end

  def test_07_json_logs_with_a_schema_url
    assert_ok(JSON_LOGS.merge("LOG_SCHEMA_URL" => "https://logs.example/v1.json"),
      "shop worker: queues default, webhooks off")
  end

  def test_08_webhooks_need_the_signing_key
    violations = assert_problems(WORKER_HOOKS, [%w[webhook-signing-key file_missing]])
    assert_includes message_for(violations, "webhook-signing-key"), ", and is required when WEBHOOKS_ENABLED is true"
  end

  def test_09_webhooks_with_the_signing_key
    key = File.join(@root, KEY_PATH)
    FileUtils.mkdir_p(File.dirname(key))
    File.write(key, "k" * 40)
    assert_ok(WORKER_HOOKS, "shop worker: queues default, webhooks on")
  end

  def test_10_the_signing_key_belongs_to_the_worker
    assert_ok({"DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "https://shop.example", "WEBHOOKS_ENABLED" => "true"},
      "shop web: port 8080, origins https://shop.example")
  end

  def test_11_fragment_vars_are_checked_at_boot
    assert_problems({"DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "https://shop.example",
                     "OTEL_EXPORTER_OTLP_PROTOCOL" => "carrier-pigeon"},
      [%w[OTEL_EXPORTER_OTLP_PROTOCOL not_in_enum]])
  end

  # The worker prints QUEUES from the typed config, a list.
  def test_queues_are_typed
    config = Shop.load(env("DOCUCONF_ROLE" => "worker", "QUEUES" => "default,mail"), termination_log: false)
    assert_equal %w[default mail], config["QUEUES"]
    assert_equal false, config["WEBHOOKS_ENABLED"]
    assert_equal %w[otel@1], Shop::CONTRACT.includes
    assert_equal %w[web worker], Shop::CONTRACT.roles
  end
end
