# frozen_string_literal: true

require "pp"

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

  it "names an empty key by its 1-based position, never a key" do
    vars = {"API_KEYS" => {"type" => "keySet", "description" => "Keys that callers present", "secret" => true,
                           "maxKeys" => 3}}
    {"old-key," => "key 2 is empty", ",new-key" => "key 1 is empty", "a-key,,b-key" => "key 2 is empty"}.each do |raw, msg|
      load(vars, {"API_KEYS" => raw})
      raise "expected a ValidationError"
    rescue Docuconf::Anyway::ValidationError => e
      expect(e.violations.map { |v| [v.input, v.code, v.message] }).to eq([["API_KEYS", :out_of_range, msg]]), raw
      expect(e.message).not_to include("-key")
    end
  end

  describe "reload: watch" do
    def watched_contract
      contract(
        {"PORT" => {"type" => "int", "description" => "Listen port", "default" => 80, "min" => 1, "configKey" => "port"}},
        "files" => {"motd" => {"type" => "text", "description" => "Message of the day", "path" => "/etc/svc/motd/motd.txt",
                               "reload" => "watch", "minLength" => 1}},
        "overlays" => {"platform" => {"format" => "json", "path" => "/etc/svc/overlay/svc.json", "keySeparator" => ".",
                                      "reload" => "watch"}}
      )
    end

    it "reloads watched files and overlays into the loaded values, with hooks and status" do
      Dir.mktmpdir do |root|
        write_file(root, "etc/svc/motd/motd.txt", "one")
        write_file(root, "etc/svc/overlay/svc.json", '{"port": 81}')
        env = {"DOCUCONF_FILE_ROOT" => root, "DOCUCONF_WATCH_INTERVAL" => "0"}
        values = Docuconf::Anyway::Contract.parse(watched_contract).load(env, termination_log: false, watch: true)
        expect(values.watcher).to be_a(Docuconf::Anyway::ContractWatcher)
        expect(values.watcher.alive?).to be false # interval 0: polled by hand here
        expect(values.reload_status.keys).to contain_exactly("motd", "overlay:platform")
        expect(values.reload_status("motd").generation).to eq 1
        expect { values.on_change("PORT") {} }.to raise_error(ArgumentError)

        seen = []
        values.on_change("motd") { |_| raise "boom" }
        values.on_change(:motd) { |v| seen << v }
        values.on_overlay_change { |v| seen << v["PORT"] }

        write_file(root, "etc/svc/motd/motd.txt", "two!")
        expect { expect(values.watcher.poll).to eq [:motd] }.to output(/on-change hook for motd raised RuntimeError/).to_stderr
        expect(values["motd"]).to eq "two!"
        expect(values.reload_status("motd")).to have_attributes(generation: 2, last_rejected: nil)

        write_file(root, "etc/svc/motd/motd.txt", "")
        expect { expect(values.watcher.poll).to eq [] }.to output(/reload of motd rejected/).to_stderr
        expect(values["motd"]).to eq "two!"
        expect(values.reload_status("motd").last_rejected.to_h).to include(input: "motd")

        write_file(root, "etc/svc/overlay/svc.json", '{"port": 8443}')
        expect(values.watcher.poll).to eq [:"overlay:platform"]
        expect(values["PORT"]).to eq 8443

        write_file(root, "etc/svc/overlay/svc.json", '{"port": 0, "x": 1}')
        expect { expect(values.watcher.poll).to eq [] }.to output(/reload of overlay platform rejected/).to_stderr
        expect(values["PORT"]).to eq 8443
        expect(values.reload_status("overlay:platform").last_rejected.codes).to eq [:out_of_range]
        expect(seen).to eq ["two!", 8443]
      end
    end

    it "starts no thread with watch: false, and polls in the background otherwise" do
      Dir.mktmpdir do |root|
        write_file(root, "etc/svc/motd/motd.txt", "one")
        env = {"DOCUCONF_FILE_ROOT" => root, "DOCUCONF_WATCH_INTERVAL" => "0.05"}
        once = Docuconf::Anyway::Contract.parse(watched_contract).load(env, termination_log: false, watch: false)
        expect(once.watcher).to be_nil
        expect(once.reload_status("motd").generation).to eq 1

        values = Docuconf::Anyway::Contract.parse(watched_contract).load(env, termination_log: false, watch: true)
        begin
          write_file(root, "etc/svc/motd/motd.txt", "background")
          deadline = Time.now + 5
          sleep 0.05 until values["motd"] == "background" || Time.now > deadline
          expect(values["motd"]).to eq "background"
          expect(once["motd"]).to eq "one"
        ensure
          values.stop_watching
        end
      end
    end
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
    expect(codes_of(vars, {"D_TIMESPAN" => "00:60:00", "D_GO" => "5S", "D_SECONDS" => "1e3"})).to contain_exactly(
      ["D_TIMESPAN", :invalid_type], ["D_GO", :invalid_type], ["D_SECONDS", :invalid_type]
    )
    # Only the go encoding has a sign (SPEC §5).
    expect(Docuconf::Anyway::Duration.to_ns(load(vars, {"D_GO" => "-5s"})["D_GO"])).to eq(-5_000_000_000)
    expect(codes_of(vars, {"D_ISO8601" => "-PT5S"})).to eq [["D_ISO8601", :invalid_type]]
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

  it "filters secrets from #inspect and pp of the loaded values" do
    values = load({"TOKEN" => {"type" => "string", "description" => "API token", "secret" => true},
                   "PORT" => {"type" => "int", "description" => "Listen port"}}, {"TOKEN" => "tok_hunter2", "PORT" => "80"})
    expect(values["TOKEN"]).to eq "tok_hunter2"
    expect(values).to eq("TOKEN" => "tok_hunter2", "PORT" => 80)
    expect(values.inspect).to include("[FILTERED]").and include("80")
    expect(values.inspect).not_to include("hunter2")
    expect(values.pretty_inspect).not_to include("hunter2")
  end
end
