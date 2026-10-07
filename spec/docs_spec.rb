# frozen_string_literal: true

RSpec.describe "description and details (SPEC §4.2, §14.7)" do
  include CueHelper

  def anon(name, &block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name name
      class_eval(&block)
    end
  end

  def contract(klass)
    Docuconf::Anyway::Exporter.new(name: "svc", classes: [klass]).contract
  end

  def problems(klass)
    contract(klass)
    raise "expected a DeclarationError"
  rescue Docuconf::Anyway::DeclarationError => e
    e.message
  end

  let(:documented) do
    anon(:docs) do
      env_prefix ""
      attr_config port: 8080, region: "eu-west-1", workers: 4, plain: "x"

      # Behind the mesh, keep the default.
      #
      # The sidecar forwards {Ingress#port} traffic here; see +PORT+ in the chart.
      describe :port, "HTTP listen port", min: 1, max: 65_535

      # Change it together with the bucket:
      #
      # - `eu-west-1` for Europe
      # - `us-east-1` for the US
      #
      # @example Switch to the US
      #   REGION=us-east-1 bin/rails server
      # @note Buckets cannot move between regions.
      # @param region [String] dropped: API docs, not configuration docs
      # @see https://example.com/regions
      describe :region, "Cloud region for object storage"

      # Ignored: the explicit option wins.
      describe :workers, "Worker processes", details: "One per *core*."

      describe :plain, "No details at all"

      # Issued per customer.
      #
      # = Rotation
      # Rotate it yearly.
      text_file :license, path: "/etc/app/license/license.key", description: "Licence key file"
    end
  end

  it "takes the description from describe and the details from the YARD comment above it" do
    port = contract(documented)["vars"]["PORT"]
    expect(port["description"]).to eq "HTTP listen port"
    expect(port["details"]).to eq "Behind the mesh, keep the default.\n\n" \
      "The sidecar forwards `Ingress#port` traffic here; see `PORT` in the chart."
    expect(port.keys.first(3)).to eq %w[type description details]
    expect(contract(documented)["vars"]["PLAIN"]).not_to have_key("details")
  end

  it "converts lists, code blocks and YARD tags to CommonMark" do
    expect(contract(documented)["vars"]["REGION"]["details"]).to eq <<~MD.chomp
      Change it together with the bucket:

      - `eu-west-1` for Europe
      - `us-east-1` for the US

      Switch to the US:

      ```ruby
      REGION=us-east-1 bin/rails server
      ```

      **Note:** Buckets cannot move between regions.

      See <https://example.com/regions>.
    MD
  end

  it "prefers the details: option" do
    expect(contract(documented)["vars"]["WORKERS"]["details"]).to eq "One per *core*."
  end

  it "reads details for file inputs, with RDoc headings as Markdown headings" do
    license = contract(documented)["files"]["license"]
    expect(license["details"]).to eq "Issued per customer.\n\n# Rotation\nRotate it yearly."
    expect(license.keys.first(3)).to eq %w[type description details]
  end

  it "converts YARD links and RDoc code outside code spans" do
    expect(Docuconf::Anyway::Docs.to_markdown("{a b} `{kept}` +x+ a + b")).to eq "`b` `{kept}` `x` a + b"
  end

  it "fails without a description" do
    klass = anon(:nodesc) do
      attr_config nothing: 3
      describe :nothing, ""
    end
    expect(problems(klass)).to include "NODESC_NOTHING: description must be at least 5 characters"
    missing = anon(:missing) { attr_config nothing: 3 }
    expect(problems(missing)).to include "MISSING_NOTHING: description is required"
  end

  it "fails on blank details" do
    klass = anon(:blank) do
      attr_config value: "x"
      describe :value, "Has blank details", details: " \n "
    end
    expect(problems(klass)).to include "BLANK_VALUE: details must not be blank"
  end

  it "fails on details over 4000 characters, counted in code points" do
    klass = anon(:long) do
      attr_config value: "x"
      describe :value, "Has long details", details: "日本" * 2000 + "!"
    end
    expect(problems(klass)).to include "LONG_VALUE: details are 4001 characters; at most 4000 are allowed"
    ok = anon(:most) do
      attr_config value: "x"
      describe :value, "Has 4000 characters of details", details: "日本" * 2000
    end
    expect(contract(ok)["vars"]["MOST_VALUE"]["details"].length).to eq 4000
  end

  it "never reads details at runtime" do
    with_env("PORT" => "9090") do
      klass = documented
      expect(klass.new.port).to eq 9090
    end
  end

  it "loads a contract with details in contract-first mode, and checks them" do
    vars = {"PORT" => {"type" => "int", "description" => "Listen port", "details" => "Keep it.\n\n- a\n- b", "default" => 8080}}
    doc = {
      "apiVersion" => "docuconf.dev/v1alpha1", "kind" => "ConfigContract",
      "metadata" => {"name" => "svc", "generator" => {"language" => "go", "sdk" => "x", "version" => "1"}},
      "vars" => vars
    }
    expect(Docuconf::Anyway.load_contract(JSON.generate(doc), env: {"PORT" => "1"}, termination_log: false)).to eq("PORT" => 1)
    vars["PORT"]["details"] = "   "
    expect { Docuconf::Anyway.load_contract(JSON.generate(doc), env: {}, termination_log: false) }
      .to raise_error(Docuconf::Anyway::DeclarationError, /details must not be blank/)
  end

  it "exports details that pass cue vet -c" do
    require_cue!
    text = Docuconf::Anyway.export(name: "svc", classes: [documented])
    expect(text).to include "details:"
    ok, out = cue_vet(text)
    expect(ok).to be(true), out
  end
end
