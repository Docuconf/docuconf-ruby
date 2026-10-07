# frozen_string_literal: true

RSpec.describe "contract-first mode" do
  def contract(vars, **extra)
    {
      "apiVersion" => "docuconf.dev/v1alpha1", "kind" => "ConfigContract",
      "metadata" => {"name" => "svc", "generator" => {"language" => "go", "sdk" => "x", "version" => "1"}},
      "vars" => vars
    }.merge(extra)
  end

  def load(vars, env, **extra)
    Docuconf::Anyway.load_contract(JSON.generate(contract(vars, **extra)), env: env, termination_log: false)
  end

  def codes_of(vars, env)
    load(vars, env)
    raise "expected a ValidationError"
  rescue Docuconf::Anyway::ValidationError => e
    e.violations.map { |v| [v.input, v.code] }
  end

  it "returns typed values, defaults and nil for absent optionals" do
    vars = {
      "PORT" => {"type" => "int", "description" => "Listen port", "default" => 8080},
      "RATIO" => {"type" => "float", "description" => "Sample ratio"},
      "HOST" => {"type" => "string", "description" => "Host name", "required" => true}
    }
    expect(load(vars, {"HOST" => "db", "RATIO" => "0.5"})).to eq("PORT" => 8080, "RATIO" => 0.5, "HOST" => "db")
  end

  it "reads every duration encoding" do
    vars = %w[go iso8601 seconds timespan].to_h do |enc|
      ["D_#{enc.upcase}", {"type" => "duration", "description" => "A duration", "encoding" => enc}]
    end
    env = {"D_GO" => "1m30s", "D_ISO8601" => "PT90.5S", "D_SECONDS" => "90.5", "D_TIMESPAN" => "1.00:01:30.5"}
    values = load(vars, env)
    expect(values.transform_values { |v| Docuconf::Anyway::Duration.to_ns(v) }).to eq(
      "D_GO" => 90_000_000_000, "D_ISO8601" => 90_500_000_000, "D_SECONDS" => 90_500_000_000,
      "D_TIMESPAN" => 86_490_500_000_000
    )
    expect(codes_of(vars, {"D_TIMESPAN" => "00:60:00", "D_GO" => "-5s", "D_SECONDS" => "1e3"})).to contain_exactly(
      ["D_TIMESPAN", :invalid_type], ["D_GO", :invalid_type], ["D_SECONDS", :invalid_type]
    )
  end

  it "reads every list encoding and checks item bounds" do
    vars = {
      "CSV" => {"type" => "list", "description" => "Csv list", "items" => "int", "encoding" => "csv", "separator" => ";"},
      "JSONL" => {"type" => "list", "description" => "Json list", "items" => "string", "encoding" => "json"},
      "IDX" => {"type" => "list", "description" => "Indexed", "items" => "int", "encoding" => "indexed", "itemMax" => 9}
    }
    env = {"CSV" => "1;2", "JSONL" => '["a,b"]', "IDX__0" => "3", "IDX__1" => "4", "IDX__HOST" => "x", "IDX__01" => "x"}
    expect(load(vars, env)).to eq("CSV" => [1, 2], "JSONL" => ["a,b"], "IDX" => [3, 4])
    expect(codes_of(vars, {"IDX__0" => "10"})).to eq [["IDX", :out_of_range]]
  end

  it "rejects gaps in an indexed list" do
    vars = {"IDX" => {"type" => "list", "description" => "Indexed", "items" => "string", "encoding" => "indexed"}}
    expect(codes_of(vars, {"IDX__0" => "a", "IDX__2" => "c"})).to eq [["IDX", :invalid_type]]
    expect(codes_of(vars, {"IDX__1" => "b"})).to eq [["IDX", :invalid_type]]
    expect { load(vars, {"IDX__0" => "a", "IDX__2" => "c"}) }.to raise_error(/IDX__1 is not set/)
  end

  it "applies the selected profile's defaults" do
    vars = {
      "APP_ENV" => {"type" => "string", "description" => "Profile selector", "default" => "dev"},
      "LEVEL" => {"type" => "enum", "description" => "Log level", "values" => %w[debug info], "default" => "info"}
    }
    profiles = {"selector" => "APP_ENV", "default" => "dev", "defaults" => {"dev" => {"LEVEL" => "debug"}}}
    expect(load(vars, {}, profiles: profiles)["LEVEL"]).to eq "debug"
    expect(load(vars, {"APP_ENV" => "prod"}, profiles: profiles)["LEVEL"]).to eq "info"
    expect(load(vars, {"LEVEL" => "info"}, profiles: profiles)["LEVEL"]).to eq "info"
  end

  it "reports every violation together and never shows a secret" do
    vars = {
      "TOKEN" => {"type" => "string", "description" => "API token", "secret" => true, "minLength" => 20},
      "PORT" => {"type" => "int", "description" => "Listen port", "required" => true}
    }
    expect { load(vars, {"TOKEN" => "hunter2"}) }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
      expect(e.violations.map { |v| [v.input, v.code] }).to contain_exactly(["TOKEN", :out_of_range], ["PORT", :missing_required])
      expect(e.message).not_to include("hunter2")
    }
  end

  it "writes the termination log" do
    Dir.mktmpdir do |dir|
      log = File.join(dir, "log")
      with_env("DOCUCONF_TERMINATION_LOG" => log) do
        c = Docuconf::Anyway::Contract.parse(contract({"N" => {"type" => "int", "description" => "A number"}}))
        expect { c.load({"N" => "x"}) }.to raise_error(Docuconf::Anyway::ValidationError)
      end
      expect(File.read(log)).to include("N [invalid_type]")
    end
  end

  it "rejects a malformed contract" do
    bad = contract({
      "A" => {"type" => "list", "description" => "Tags", "items" => "string", "itemMax" => 3},
      "B" => {"type" => "duration", "description" => "Timeout", "encoding" => "minutes"},
      "C" => {"type" => "string", "description" => "Code", "pattern" => "(?=x)"}
    })
    expect { Docuconf::Anyway::Contract.parse(bad) }.to raise_error(Docuconf::Anyway::DeclarationError) { |e|
      expect(e.problems).to contain_exactly(
        "A: itemMin and itemMax apply only to lists of int",
        "B: unknown duration encoding \"minutes\"",
        "C: pattern is not RE2: lookahead (?=...)"
      )
    }
    expect { Docuconf::Anyway::Contract.parse("{") }.to raise_error(Docuconf::Anyway::DeclarationError, /not valid JSON/)
  end
end
