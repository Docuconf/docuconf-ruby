# frozen_string_literal: true

# The webhook key set: a rotation, step by step, and the key sets that fail
# at boot. Run with: bundle exec ruby test/webhook_test.rb
require "bundler/setup"
require "minitest/autorun"
require "openssl"
require_relative "../config/orders_config"
require_relative "../webhook"

class WebhookTest < Minitest::Test
  OLD = "o" * 32
  NEW = "n" * 32
  BODY = '{"order":"42","status":"paid"}'
  BASE = {"DATABASE_URL" => "postgres://orders:pw@db:5432/orders"}.freeze

  def sign(key) = OpenSSL::HMAC.hexdigest("SHA256", key, BODY)

  # WEBHOOK_KEYS as the service loads it at boot.
  def keys(value) = OrdersConfig.from_env(BASE.merge("WEBHOOK_KEYS" => value)).webhook_keys

  def test_rotation
    {
      "before" => [OLD, {OLD => true, NEW => false}],
      "overlap" => ["#{OLD},#{NEW}", {OLD => true, NEW => true}],
      "after" => [NEW, {OLD => false, NEW => true}]
    }.each do |step, (value, accepts)|
      ks = keys(value)
      accepts.each { |key, want| assert_equal want, Webhook.verify(ks, BODY, sign(key)), "#{step}: key #{key[0]}" }
    end
  end

  def test_bad_signatures
    ks = keys(OLD)
    refute Webhook.verify(ks, BODY, nil)
    refute Webhook.verify(ks, BODY, "not hex")
    refute Webhook.verify(ks, BODY, sign("x" * 32))
    refute Webhook.verify(ks, "#{BODY} ", sign(OLD))
    refute Webhook.verify(nil, BODY, sign(OLD))
  end

  def test_optional
    assert_nil OrdersConfig.from_env(BASE).webhook_keys
  end

  def test_bad_key_sets_fail_at_boot_without_printing_a_key
    {
      "#{OLD}," => :out_of_range, # an empty second key
      "#{OLD},#{NEW[0, 10]}" => :out_of_range, # a truncated key
      "#{OLD},#{NEW},#{"x" * 32}" => :too_many_items
    }.each do |value, code|
      e = assert_raises(Docuconf::Anyway::ValidationError) { keys(value) }
      assert_equal [["WEBHOOK_KEYS", code]], e.violations.map { |v| [v.input, v.code] }, value
      refute_includes e.message, OLD
      refute_includes e.message, NEW[0, 10]
    end
  end
end
