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
end
