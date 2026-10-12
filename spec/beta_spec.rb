# frozen_string_literal: true

require "pp"
require "openssl"

# Declaration mode: the keySet type, deprecated rules and strict parsing.
RSpec.describe "key sets, deprecated inputs and strict parsing" do
  def config(&block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :beta
      env_prefix ""
      class_eval(&block)
    end
  end

  def problems(&block)
    config(&block).docuconf_declaration
    raise "expected a DeclarationError"
  rescue Docuconf::Anyway::DeclarationError => e
    e.problems
  end

  def load_error(klass, env)
    klass.from_env(env)
    raise "expected a ValidationError"
  rescue Docuconf::Anyway::ValidationError => e
    e
  end

  OLD = "old-webhook-key-0123456789abcdef0123"
  NEW = "new-webhook-key-0123456789abcdef0123"

  let(:webhook) do
    config do
      attr_config :webhook_keys
      describe :webhook_keys, "Keys that verify webhook signatures", type: :key_set,
        key_min_length: 32, key_max_length: 256
    end
  end

  describe "keySet" do
    it "exports as a keySet, always secret" do
      expect(webhook.docuconf_declaration.var(:webhook_keys).to_contract).to eq(
        "type" => "keySet", "description" => "Keys that verify webhook signatures", "secret" => true,
        "configKey" => "beta.webhook_keys", "encoding" => "csv", "separator" => ",",
        "minKeys" => 1, "maxKeys" => 2, "keyMinLength" => 32, "keyMaxLength" => 256
      )
    end

    it "loads the keys in order, never trimmed" do
      keys = webhook.from_env("WEBHOOK_KEYS" => "#{OLD}, #{NEW}").webhook_keys
      expect(keys).to be_a(Docuconf::Anyway::KeySet)
      expect(keys.keys).to eq [OLD, " #{NEW}"]
      expect(webhook.from_env("WEBHOOK_KEYS" => "").webhook_keys).to be_nil
    end

    it "offers contains? and verify, and never shows a key" do
      keys = webhook.from_env("WEBHOOK_KEYS" => "#{OLD},#{NEW}").webhook_keys
      expect(keys.contains?(NEW)).to be true
      expect(keys.contains?(NEW[0..-2])).to be false
      expect(keys.contains?(nil)).to be false
      body = "payload"
      sig = OpenSSL::HMAC.hexdigest("SHA256", NEW, body)
      tried = []
      ok = keys.verify do |key|
        tried << key
        OpenSSL.secure_compare(OpenSSL::HMAC.hexdigest("SHA256", key, body), sig)
      end
      expect(ok).to be true
      expect(tried).to eq [OLD, NEW]
      expect(keys.verify { false }).to be false
      [keys.to_s, keys.inspect, keys.pretty_inspect, keys.to_json, webhook.from_env("WEBHOOK_KEYS" => OLD).inspect]
        .each { |shown| expect(shown).not_to include("webhook-key") }
    end

    it "reports too few and too many keys, and bad key lengths, without a key" do
      {
        "#{OLD}," => :out_of_range,
        "#{OLD},new-webhook-key" => :out_of_range,
        "#{"k" * 257}" => :out_of_range,
        "#{OLD},#{NEW},#{OLD}x" => :too_many_items
      }.each do |raw, code|
        e = load_error(webhook, "WEBHOOK_KEYS" => raw)
        expect(codes(e)).to eq([["WEBHOOK_KEYS", code]]), raw
        expect(e.message).not_to include("webhook-key")
        expect(e.message).not_to include("kkkk")
      end
    end

    it "names an empty key by its 1-based position, never a key" do
      k = config do
        attr_config :api_keys
        describe :api_keys, "Keys that callers present", type: :key_set, max_keys: 3
      end
      {"old-key," => "key 2 is empty", ",new-key" => "key 1 is empty", "a-key,,b-key" => "key 2 is empty"}.each do |raw, msg|
        e = load_error(k, "API_KEYS" => raw)
        expect(e.violations.map { |v| [v.input, v.code, v.message] }).to eq([["API_KEYS", :out_of_range, msg]]), raw
        expect(e.message).not_to include("-key")
      end
    end

    it "reads min_keys, max_keys and a separator" do
      k = config do
        attr_config :api_keys
        describe :api_keys, "Keys that callers present", type: :key_set, min_keys: 2, max_keys: 3, separator: ";"
      end
      expect(k.from_env("API_KEYS" => "a,b;c").api_keys.keys).to eq ["a,b", "c"]
      expect(codes(load_error(k, "API_KEYS" => "a"))).to eq [["API_KEYS", :too_few_items]]
    end

    it "checks its declaration" do
      expect(problems { attr_config :k; describe :k, "Some keys", type: :key_set, secret: false })
        .to eq ["K: a key set is always secret; remove secret: false"]
      expect(problems { attr_config :k; describe :k, "Some keys", type: :key_set, min_keys: 0 })
        .to eq ["K: min_keys 0 must be an integer of at least 1"]
      expect(problems { attr_config :k; describe :k, "Some keys", type: :key_set, min_keys: 3 })
        .to eq ["K: max_keys 2 is below min_keys 3"]
      expect(problems { attr_config :k; describe :k, "Some keys", type: :key_set, key_min_length: 9, key_max_length: 8 })
        .to eq ["K: key_min_length 9 is above key_max_length 8"]
      expect(problems { attr_config k: "abc"; describe :k, "Some keys", type: :key_set })
        .to eq ["K: a secret must not have a default (it would ship in the image)"]
      expect(problems { attr_config :k; describe :k, "Some keys", min_keys: 1 })
        .to include(a_string_including("K: min_keys applies to keySet variables"))
    end

    it "loads in contract-first mode as a KeySet" do
      contract = Docuconf::Anyway::Contract.parse(
        "apiVersion" => Docuconf::Anyway::API_VERSION, "kind" => "ConfigContract", "metadata" => {"name" => "x"},
        "vars" => {"K" => {"type" => "keySet", "description" => "Some keys", "secret" => true, "encoding" => "json"}}
      )
      values = contract.load({"K" => '["a","b"]'}, termination_log: false)
      expect(values["K"]).to be_a(Docuconf::Anyway::KeySet)
      expect(values["K"].keys).to eq %w[a b]
      expect(values.inspect).not_to include('"a"')
    end
  end

  describe "deprecated" do
    it "warns at boot naming the input and message, never the value" do
      k = config do
        attr_config :old_port
        describe :old_port, "Old name of the listen port", min: 1,
          deprecated: {message: "Use LISTEN_PORT instead", replaced_by: "LISTEN_PORT"}
      end
      # Each warning is printed once per process.
      expect { expect(k.from_env("OLD_PORT" => "9090").old_port).to eq 9090 }
        .to output(/OLD_PORT is deprecated: Use LISTEN_PORT instead \(replaced by LISTEN_PORT\)/).to_stderr
      expect { k.from_env("OLD_PORT" => "9091") }.not_to output(/9091/).to_stderr
      expect(codes(load_error(k, "OLD_PORT" => "0"))).to eq [["OLD_PORT", :out_of_range]]
    end

    it "rejects a blank or long message, a required input and a bad replaced_by" do
      expect(problems { attr_config :a; describe :a, "Some value", deprecated: " " })
        .to eq ["A: deprecated must say what to use instead, or why the input is going away"]
      expect(problems { attr_config :a; describe :a, "Some value", deprecated: "x" * 501 })
        .to eq ["A: deprecated message must be at most 500 characters"]
      expect { config { attr_config :a; describe :a, "Some value", deprecated: "x" * 500 }.docuconf_declaration }
        .not_to raise_error
    end

    it "rejects a deprecated required input" do
      expect(problems { attr_config :a; required :a; describe :a, "Some value", deprecated: "Going away" })
        .to eq ["A: a required variable cannot be deprecated: deprecating it asks the platform to stop setting it"]
      expect(problems { attr_config :a; describe :a, "Some value", deprecated: {message: "Going", replaced_by: "b"} })
        .to eq ["A: replaced_by \"b\" must be a variable name"]
      expect(problems do
        text_file :licence, path: "/etc/beta/licence/licence.key", description: "Licence key", required: true,
          deprecated: "Use the new licence"
      end).to eq ["file licence: a required file input cannot be deprecated: deprecating it asks the platform to stop supplying it"]
    end
  end

  describe "strict parsing (SPEC §5)" do
    let(:strict) do
      config do
        attr_config :flag, :count, :ratio, :names, :ids
        coerce_types names: {type: :string, array: true}, ids: {type: :integer!, array: true}, count: :integer!
        describe :flag, "A switch", type: :bool
        describe :count, "A count"
        describe :ratio, "A ratio", type: :float
        describe :names, "Some names"
        describe :ids, "Some ids"
      end
    end

    it "accepts true and false in any case, and nothing else" do
      expect(strict.from_env("FLAG" => "TRUE").flag).to be true
      expect(strict.from_env("FLAG" => "False").flag).to be false
      %w[1 0 t f yes no on off].push(" true", "true\n").each do |raw|
        expect(codes(load_error(strict, "FLAG" => raw))).to eq([["FLAG", :invalid_type]]), raw
      end
    end

    it "reads ints in decimal, whatever the host's coercion" do
      expect(strict.from_env("COUNT" => "010").count).to eq 10
      expect(strict.from_env("IDS" => "+1,007,-0").ids).to eq [1, 7, 0]
      %w[0x10 1_000 1e3].push("5\n").each do |raw|
        expect(codes(load_error(strict, "COUNT" => raw))).to eq([["COUNT", :invalid_type]]), raw
      end
      expect(codes(load_error(strict, "IDS" => "1, 2"))).to eq [["IDS", :invalid_type]]
    end

    it "reads floats only in decimal" do
      expect(strict.from_env("RATIO" => "25e-2").ratio).to eq 0.25
      %w[.5 5. inf NaN 0x1p4 1e400].each do |raw|
        expect(codes(load_error(strict, "RATIO" => raw))).to eq([["RATIO", :invalid_type]]), raw
      end
    end

    it "never trims csv items" do
      expect(strict.from_env("NAMES" => "a, b ,c").names).to eq ["a", " b ", "c"]
      expect(strict.from_env("NAMES" => "a,,b,").names).to eq ["a", "", "b", ""]
    end
  end
end
