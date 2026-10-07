# frozen_string_literal: true

RSpec.describe "declaration checks" do
  def config(&block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :decl
      class_eval(&block)
    end
  end

  def problems(&block)
    config(&block).docuconf_declaration
    raise "expected a DeclarationError"
  rescue Docuconf::Anyway::DeclarationError => e
    e.problems
  end

  it "requires a description of at least 5 characters" do
    expect(problems { attr_config :a, :b; describe :b, "abc" }).to contain_exactly(
      a_string_including("DECL_A: description is required"),
      "DECL_B: description must be at least 5 characters"
    )
  end

  it "rejects non-RE2 patterns" do
    expect(problems { attr_config :a; describe :a, "Some value", pattern: "^(?=x)" })
      .to eq ["DECL_A: pattern is not RE2: lookahead (?=...)"]
    expect(problems { attr_config :a; describe :a, "Some value", pattern: "(a)\\1" })
      .to eq ["DECL_A: pattern is not RE2: backreference \\1"]
  end

  it "checks defaults against their own constraints" do
    expect(problems { attr_config port: 0; describe :port, "Listen port", min: 1 })
      .to eq ["DECL_PORT: default 0 is below min 1"]
    expect(problems { attr_config level: "x"; describe :level, "Log level", values: %w[a b] })
      .to eq ["DECL_LEVEL: default \"x\" is not one of a, b"]
    expect(problems { attr_config t: "PT10M"; coerce_types t: :duration; describe :t, "Timeout", max: "5m" })
      .to eq ["DECL_T: default 10m is above max 5m"]
  end

  it "allows item bounds only on int lists, within 64 bits, in order" do
    expect(problems {
      attr_config tags: [], shards: [], big: [], order: []
      coerce_types tags: {type: :string, array: true}, shards: {type: :integer, array: true},
        big: {type: :integer, array: true}, order: {type: :integer, array: true}
      describe :tags, "Tags to apply", item_max: 3
      describe :shards, "Shards owned", item_min: 0, item_max: 1023
      describe :big, "Too big bounds", item_max: 2**63
      describe :order, "Bounds reversed", item_min: 5, item_max: 1
    }).to contain_exactly(
      "DECL_TAGS: item_min and item_max apply only to lists of int",
      "DECL_BIG: item_max 9223372036854775808 is not a 64-bit integer",
      "DECL_ORDER: item_min 5 is above item_max 1"
    )
    expect(problems { attr_config shards: [0, 2000]; describe :shards, "Shards owned", item_max: 1023 })
      .to eq ["DECL_SHARDS: default item 1 (2000) is above item_max 1023"]
  end

  it "rejects secrets with defaults or examples" do
    expect(problems { attr_config token: "abc"; describe :token, "API token"; secret :token })
      .to eq ["DECL_TOKEN: a secret must not have a default (it would ship in the image)"]
    expect(problems { attr_config :token; describe :token, "API token", examples: ["x"]; secret :token })
      .to eq ["DECL_TOKEN: a secret must not have examples"]
  end

  it "rejects unknown options at definition time" do
    expect { config { attr_config :a; describe :a, "Some value", minimum: 1 } }
      .to raise_error(ArgumentError, /unknown docuconf option/)
  end

  it "rejects coercions with no contract type" do
    expect(problems { attr_config :d; coerce_types d: :date; describe :d, "Some date" })
      .to eq ["DECL_D: coercion :date has no contract type; add type: to describe"]
  end

  it "exports a required attribute with a default as optional" do
    klass = config { attr_config port: 80; required :port; describe :port, "Listen port" }
    expect(klass.docuconf_declaration.var(:port).required).to be false
  end

  it "leaves nested settings file-only, with a warning" do
    klass = config { attr_config db: {host: "x"}, port: 1; describe :port, "Listen port" }
    expect { klass.docuconf_declaration }.to output(/nested setting/).to_stderr
    expect(klass.docuconf_declaration.vars.map(&:name)).to eq ["DECL_PORT"]
  end

  it "checks file paths and mounts" do
    expect(problems {
      text_file :a, path: "etc/x", description: "Relative path"
      text_file :b, path: "/etc/x.txt", description: "In a reserved directory"
      text_file :c, path: "/srv/app/x/../y", description: "Not normalised"
      text_file :d, path: "/srv/one/d.txt", description: "First in /srv/one"
      text_file :e, path: "/srv/one/e.txt", description: "Second in /srv/one"
    }).to contain_exactly(
      "file a: path \"etc/x\" must be absolute and normalised",
      "file b: mount directory /etc is reserved; mounting there would hide the image's files",
      "file c: path \"/srv/app/x/../y\" must be absolute and normalised",
      "file e: shares mount directory /srv/one with d; one mount would hide the other"
    )
  end

  it "requires a keystore password variable to be a secret" do
    expect(problems {
      attr_config :ks_password
      describe :ks_password, "Keystore password"
      keystore_file :ks, path: "/srv/ks/ks.p12", description: "A keystore", password_var: :ks_password
    }).to eq ["file ks: password_var DECL_KS_PASSWORD must be a secret variable (secret :ks_password)"]
  end

  it "rejects a pathEnv that is also a variable" do
    expect(problems {
      env_prefix ""
      attr_config :routes_file
      describe :routes_file, "Where routes are"
      config_file :routes, format: :yaml, path: "/srv/r/routes.yaml", path_env: "ROUTES_FILE", description: "Routes file"
    }).to eq ["file routes: path_env ROUTES_FILE must not also be a declared variable"]
  end

  it "rejects JSON Schema keywords the validator cannot enforce" do
    expect {
      config { config_file :x, format: :json, path: "/srv/x/x.json", description: "Some file", json_schema: {"$ref" => "#/a"} }
    }.to raise_error(Docuconf::Anyway::DeclarationError, %r{file x: schema /\$ref: keyword \$ref is not supported})
  end

  describe "constraints and types" do
    def contract_var(klass, name)
      Docuconf::Anyway::Exporter.new(name: "decl", classes: [klass]).contract["vars"][name]
    end

    it "infers the type from the constraints when nothing else decides it" do
      klass = config do
        attr_config :port, :timeout, :ratio, :origins, :ports, :hook, mode: "8080"
        describe :port, "HTTP listen port", min: 1, max: 65_535
        describe :mode, "Port from a string default", min: 1
        describe :timeout, "Request timeout", min: "1s", max: "5m"
        describe :ratio, "Sampling ratio", min: 0.0, max: 1.0
        describe :origins, "CORS origins", min_items: 1
        describe :ports, "Worker ports", item_min: 1
        describe :hook, "Callback URL", schemes: %w[https]
      end
      expect(contract_var(klass, "DECL_PORT")).to include("type" => "int", "min" => 1, "max" => 65_535)
      expect(contract_var(klass, "DECL_MODE")).to include("type" => "int", "min" => 1, "default" => 8080)
      expect(contract_var(klass, "DECL_TIMEOUT")).to include("type" => "duration", "min" => "1s", "max" => "5m")
      expect(contract_var(klass, "DECL_RATIO")).to include("type" => "float", "max" => 1.0)
      expect(contract_var(klass, "DECL_ORIGINS")).to include("type" => "list", "items" => "string", "minItems" => 1)
      expect(contract_var(klass, "DECL_PORTS")).to include("type" => "list", "items" => "int", "itemMin" => 1)
      expect(contract_var(klass, "DECL_HOOK")).to include("type" => "url", "schemes" => ["https"])

      with_env("DECL_PORT" => "70000") do
        expect { klass.new }.to raise_error(Docuconf::Anyway::ValidationError, /DECL_PORT \[out_of_range\]: 70000 is above max 65535/)
      end
      with_env("DECL_PORT" => "443") { expect(klass.new.port).to eq 443 }
    end

    it "rejects a constraint that does not fit the type, naming the fix" do
      expect(problems { attr_config debug: false; describe :debug, "Debug mode", min: 3 })
        .to eq ["DECL_DEBUG: min applies to int, float or duration variables, but DECL_DEBUG is a bool (from its " \
          "coercion or default). Add type: to `describe :debug` (for example type: :int), or give a default of that type"]
      expect(problems { attr_config name: "x"; describe :name, "Some name", min_items: 2 })
        .to contain_exactly(a_string_including("DECL_NAME: min_items applies to list variables, but DECL_NAME is a string"))
      expect(problems { attr_config port: 1; describe :port, "Listen port", min_length: 2 })
        .to contain_exactly(a_string_including("DECL_PORT: min_length applies to string variables, but DECL_PORT is a int"))
      expect(problems { attr_config :u; coerce_types u: :string; describe :u, "Some url", schemes: %w[https] })
        .to contain_exactly(a_string_including("DECL_U: schemes applies to url variables"))
      expect(problems { attr_config t: 5; describe :t, "Some value", min: "1s" })
        .to eq ['DECL_T: min "1s" is not an integer; for a duration, add type: :duration to `describe :t`']
    end

    it "lists the enum values when a default is not one of them" do
      expect(problems { attr_config level: 8080; describe :level, "Log level", values: %w[a b] })
        .to eq ["DECL_LEVEL: default 8080 is not one of a, b"]
    end

    it "explains a bad variable name in words, not a regex" do
      expect(problems { env_prefix "x-y"; attr_config port: 1; describe :port, "Listen port" }.first)
        .to include("uppercase letters, digits and '_'").and(satisfy { |m| !m.include?("\\A") })
    end
  end

  describe "describe without the include" do
    it "raises instead of falling through to another describe (RSpec's monkey patch)" do
      stray = Module.new do
        def describe(*) = :example_group
      end
      Module.include(stray)
      expect {
        Class.new(Anyway::Config) do
          config_name :noinc
          attr_config port: 8080
          describe :port, "HTTP port", min: 1
        end
      }.to raise_error(NoMethodError, /describe needs `include Docuconf::Anyway`/)
    ensure
      stray.send(:remove_method, :describe)
    end
  end
end
