# frozen_string_literal: true

# Length limits (SPEC §4.3): max_length on url and json values, and
# item_min_length/item_max_length on each item of a string list. Lengths
# count characters (Unicode code points), never bytes.
RSpec.describe "length limits" do
  def config(&block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :len
      class_eval(&block)
    end
  end

  def lengths_class
    config do
      attr_config :callback, :limits, :branches, :db_url
      coerce_types callback: :uri, limits: :json, branches: {type: :string, array: true}, db_url: :uri
      describe :callback, "Where to report each run", schemes: %w[https], max_length: 24
      describe :limits, "Run limits as a JSON object", max_length: 16
      describe :branches, "Branch codes, two to four characters each", item_min_length: 2, item_max_length: 4
      describe :db_url, "Database connection string", secret: true, max_length: 30
    end
  end

  def problems(&block)
    config(&block).docuconf_declaration
    raise "expected a DeclarationError"
  rescue Docuconf::Anyway::DeclarationError => e
    e.problems
  end

  def violations(env)
    klass = lengths_class
    with_env(env) { klass.new }
    raise "expected a ValidationError"
  rescue Docuconf::Anyway::ValidationError => e
    e
  end

  it "accepts values at the limits, counting code points, not bytes" do
    klass = lengths_class
    with_env(
      "LEN_CALLBACK" => "https://例え.jp/日本語の道/一二三四", "LEN_LIMITS" => '{"n":"日本語の道路xy"}',
      "LEN_BRANCHES" => "ZÜ01,日本,🚀🚀"
    ) do
      c = klass.new
      expect(c.limits).to eq("n" => "日本語の道路xy")
      # Under a C locale the environment is binary; compare as UTF-8.
      expect(c.branches.map { |b| b.dup.force_encoding(Encoding::UTF_8) }).to eq %w[ZÜ01 日本 🚀🚀]
    end
    with_env("LEN_CALLBACK" => "https://a.example/runs/4", "LEN_LIMITS" => '{"max":12345678}') do
      expect(klass.new.limits).to eq("max" => 12_345_678)
    end
  end

  it "reports a url above max_length as out_of_range" do
    e = violations("LEN_CALLBACK" => "https://例え.jp/日本語の道/一二三四五")
    expect(codes(e)).to eq [["LEN_CALLBACK", :out_of_range]]
    expect(e.message).to include("is 25 characters, above maxLength 24")
  end

  it "measures a json value as received, whitespace included" do
    expect(codes(violations("LEN_LIMITS" => '{"max":123456789}'))).to eq [["LEN_LIMITS", :out_of_range]]
    e = violations("LEN_LIMITS" => '{ "max": 123456 }')
    expect(codes(e)).to eq [["LEN_LIMITS", :out_of_range]]
    expect(e.message).to include("LEN_LIMITS [out_of_range]: is 17 characters of JSON, above maxLength 16")
  end

  it "measures a json value from YAML as compact JSON" do
    klass = lengths_class
    Dir.mktmpdir do |dir|
      path = write_file(dir, "config/len.yml", "limits:\n  max:      12345678\n")
      with_env("LEN_CONF" => path) { expect(klass.new.limits).to eq("max" => 12_345_678) }
      File.write(path, "limits:\n  max: 123456789\n")
      with_env("LEN_CONF" => path) do
        expect { klass.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
          expect(codes(e)).to eq [["LEN_LIMITS", :out_of_range]]
        }
      end
    end
  end

  it "checks each list item after splitting, so the separator is not counted" do
    e = violations("LEN_BRANCHES" => "BE,ZÜRICH")
    expect(codes(e)).to eq [["LEN_BRANCHES", :out_of_range]]
    expect(e.message).to include("item 1 (").and include("is 6 characters, above item_max_length 4")
    e = violations("LEN_BRANCHES" => "BE,B")
    expect(e.message).to include('item 1 ("B") is 1 characters, below item_min_length 2')
    # An emoji is one code point (two UTF-16 units).
    expect(codes(violations("LEN_BRANCHES" => "🚀"))).to eq [["LEN_BRANCHES", :out_of_range]]
  end

  it "keeps empty items, so a trailing or doubled separator fails the item length" do
    e = violations("LEN_BRANCHES" => "BE,")
    expect(codes(e)).to eq [["LEN_BRANCHES", :out_of_range]]
    expect(e.message).to include("item 1").and include("below item_min_length 2")
    expect(codes(violations("LEN_BRANCHES" => "BE,,ZH"))).to eq [["LEN_BRANCHES", :out_of_range]]
  end

  it "reports a too-long secret by its length, never its value" do
    e = violations("LEN_DB_URL" => "postgres://app:s3cr3t@db:5432/app")
    expect(codes(e)).to eq [["LEN_DB_URL", :out_of_range]]
    expect(e.message).to include("the value is 33 characters, above maxLength 30")
    expect(e.message).not_to include("s3cr3t")
  end

  it "exports maxLength, itemMinLength and itemMaxLength" do
    vars = Docuconf::Anyway::Exporter.new(name: "len", classes: [lengths_class]).contract["vars"]
    expect(vars["LEN_CALLBACK"]).to include("type" => "url", "maxLength" => 24)
    expect(vars["LEN_LIMITS"]).to include("type" => "json", "maxLength" => 16)
    expect(vars["LEN_BRANCHES"]).to include("type" => "list", "items" => "string", "itemMinLength" => 2, "itemMaxLength" => 4)
    expect(vars["LEN_DB_URL"]).to include("maxLength" => 30)
  end

  it "infers a string list from item lengths" do
    klass = config do
      attr_config :codes
      describe :codes, "Branch codes", item_max_length: 4
    end
    vars = Docuconf::Anyway::Exporter.new(name: "len", classes: [klass]).contract["vars"]
    expect(vars["LEN_CODES"]).to include("type" => "list", "items" => "string", "itemMaxLength" => 4)
  end

  it "rejects item lengths on an int list, max_length on the wrong type, and bounds out of order" do
    expect(problems {
      attr_config ports: [], tags: [], port: 1, neg: []
      coerce_types ports: {type: :integer, array: true}, tags: {type: :string, array: true},
        neg: {type: :string, array: true}
      describe :ports, "Worker ports", item_max_length: 4
      describe :tags, "Tags to apply", item_min_length: 5, item_max_length: 1
      describe :port, "Listen port", max_length: 5
      describe :neg, "Negative bound", item_max_length: -1
    }).to contain_exactly(
      "LEN_PORTS: item_min_length and item_max_length apply only to lists of string",
      "LEN_TAGS: item_min_length 5 is above item_max_length 1",
      a_string_including("LEN_PORT: max_length applies to string, url or json variables, but LEN_PORT is a int"),
      "LEN_NEG: item_max_length -1 is not a non-negative integer"
    )
  end

  it "checks defaults against the limits" do
    expect(problems {
      attr_config hook: "https://a.example/long", limits: {"max" => 123_456_789}, codes: %w[BE ZÜRICH]
      coerce_types hook: :uri, limits: :json, codes: {type: :string, array: true}
      describe :hook, "Callback URL", max_length: 10
      describe :limits, "Run limits", type: :json, max_length: 16
      describe :codes, "Branch codes", item_max_length: 4
    }).to contain_exactly(
      "LEN_HOOK: default \"https://a.example/long\" is 22 characters, above maxLength 10",
      "LEN_LIMITS: default is 17 characters of JSON, above maxLength 16",
      a_string_matching(/\ALEN_CODES: default item 1 \(.*\) is 6 characters, above item_max_length 4\z/)
    )
  end

  describe "contract-first mode" do
    def contract(vars)
      {
        "apiVersion" => "docuconf.dev/v1alpha1", "kind" => "ConfigContract",
        "metadata" => {"name" => "svc", "generator" => {"language" => "go", "sdk" => "x", "version" => "1"}},
        "vars" => vars
      }
    end

    let(:vars) do
      {
        "CALLBACK" => {"type" => "url", "description" => "Callback URL", "maxLength" => 24},
        "LIMITS" => {"type" => "json", "description" => "Run limits", "maxLength" => 16},
        "IDX" => {"type" => "list", "description" => "Branch codes", "items" => "string", "encoding" => "indexed",
                  "itemMinLength" => 2, "itemMaxLength" => 4}
      }
    end

    def load(vars, env) = Docuconf::Anyway.load_contract(contract(vars), env: env, termination_log: false)

    it "enforces the limits at boot" do
      expect(load(vars, {"IDX__0" => "ZÜ01", "IDX__1" => "日本"})["IDX"]).to eq %w[ZÜ01 日本]
      expect { load(vars, {"CALLBACK" => "https://a.example/runs/42", "LIMITS" => '{ "max": 1 }', "IDX__0" => "GENEVA"}) }
        .to raise_error(Docuconf::Anyway::ValidationError) { |e|
          expect(e.violations.map { |v| [v.input, v.code] }).to contain_exactly(
            ["CALLBACK", :out_of_range], ["IDX", :out_of_range]
          )
        }
      expect { load(vars, {"LIMITS" => '{ "max": 123456 }'}) }.to raise_error(Docuconf::Anyway::ValidationError, /LIMITS \[out_of_range\]/)
    end

    it "rejects item lengths on an int list and checks the default" do
      bad = {
        "INTS" => {"type" => "list", "description" => "Ports", "items" => "int", "itemMaxLength" => 4},
        "J" => {"type" => "json", "description" => "Limits", "maxLength" => 5, "default" => {"max" => 1}}
      }
      expect { Docuconf::Anyway::Contract.parse(contract(bad)) }.to raise_error(Docuconf::Anyway::DeclarationError) { |e|
        expect(e.problems).to contain_exactly(
          "INTS: itemMinLength and itemMaxLength apply only to lists of string",
          "J: default is 9 characters of JSON, above maxLength 5"
        )
      }
    end
  end
end
