# frozen_string_literal: true

RSpec.describe "config-file overlays" do
  OVERLAY = "etc/ovl/overlay/ovl.yml"

  def ovl_class(reload: :restart, &block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :ovl
      attr_config :token, port: 80, log_level: "info", timeout: "PT30S", hosts: ["a"]
      coerce_types port: :integer, timeout: :duration, hosts: {type: :string, array: true}
      describe :port, "HTTP listen port", min: 1, max: 65_535
      describe :log_level, "Minimum log level", values: %w[debug info warn error]
      describe :timeout, "Request timeout"
      describe :hosts, "Upstream hosts"
      describe :token, "API token"
      secret :token
      config_overlay :platform, path: "/etc/ovl/overlay/ovl.yml", reload: reload, description: "Platform settings"
      class_eval(&block) if block
    end
  end

  # A temporary app: config/ovl.yml baked in, the overlay under
  # DOCUCONF_FILE_ROOT, and a clean OVL_ environment.
  def in_app(yml: nil, overlay: nil, env: {})
    Dir.mktmpdir("docuconf-ovl") do |root|
      write_file(root, "config/ovl.yml", yml) if yml
      write_file(root, OVERLAY, overlay) if overlay
      without_prefix("OVL_") do
        with_env({"DOCUCONF_FILE_ROOT" => root, "OVL_CONF" => File.join(root, "config/ovl.yml")}.merge(env)) do
          yield root
        end
      end
    end
  end

  it "is registered with anyway_config between the YAML loaders and the environment" do
    keys = Anyway.loaders.keys
    expect(keys).to include(:docuconf_overlay)
    expect(keys.index(:docuconf_overlay)).to be > keys.index(:yml)
    expect(keys.index(:docuconf_overlay)).to eq keys.index(:env) - 1
  end

  it "is still loaded before :env when anyway_config froze its loaders before docuconf was required" do
    frozen = Anyway::Loaders::Registry.new
    frozen.append :yml, Anyway::Loaders::YAML
    frozen.append :env, Anyway::Loaders::Env
    frozen.freeze
    expect(Docuconf::Anyway::OverlayLoader.register(frozen)).to be false
    allow(Anyway).to receive(:loaders).and_return(frozen)
    in_app(yml: "port: 81\nlog_level: debug\n", overlay: "ovl:\n  port: 82\n  log_level: warn\n",
      env: {"OVL_PORT" => "83"}) do
      c = ovl_class.new
      expect([c.port, c.log_level]).to eq [83, "warn"]
    end
  end

  it "beats config/<name>.yml, and the environment beats it" do
    in_app(
      yml: "port: 81\nlog_level: debug\ntimeout: PT5S\n",
      overlay: "ovl:\n  port: 82\n  log_level: warn\n  hosts: [x, y]\n",
      env: {"OVL_PORT" => "83"}
    ) do
      c = ovl_class.new
      expect(c.port).to eq 83          # environment
      expect(c.log_level).to eq "warn" # overlay over YAML
      expect(c.hosts).to eq %w[x y]    # overlay over default
      expect(c.timeout).to eq 5        # YAML, not in the overlay
    end
  end

  it "is optional: a missing overlay is fine" do
    in_app(yml: "port: 81\n") do
      expect(ovl_class.new.port).to eq 81
    end
  end

  it "validates overlay values like any other" do
    in_app(overlay: "ovl:\n  port: 70000\n  log_level: loud\n  timeout: soon\n") do
      expect { ovl_class.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to contain_exactly(
          ["OVL_PORT", :out_of_range], ["OVL_LOG_LEVEL", :not_in_enum], ["OVL_TIMEOUT", :invalid_type]
        )
      }
    end
  end

  it "reports a malformed overlay" do
    in_app(overlay: "ovl: [unclosed\n") do
      expect { ovl_class.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["platform", :file_malformed]]
        expect(e.violations.first.kind).to eq :overlay
      }
    end
    in_app(overlay: "- a list\n") do
      expect { ovl_class.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["platform", :file_malformed]]
      }
    end
  end

  it "ignores a secret in an overlay, with a warning" do
    in_app(overlay: "ovl:\n  token: from-a-configmap\n") do
      expect { expect(ovl_class.new.token).to be_nil }.to output(/sets the secret OVL_TOKEN, which is ignored/).to_stderr
    end
  end

  it "reads values at a custom config_key" do
    klass = ovl_class { describe :port, "HTTP listen port", config_key: "ovl.http.port" }
    in_app(overlay: "ovl:\n  port: 1\n  http:\n    port: 8443\n") do
      expect(klass.new.port).to eq 8443
    end
  end

  it "is loaded even when configuration_sources leaves it out" do
    klass = ovl_class { self.configuration_sources = %i[env] }
    in_app(yml: "port: 81\n", overlay: "ovl:\n  port: 82\n") do
      expect(klass.new.port).to eq 82
    end
  end

  describe "declaration" do
    it "rejects bad overlays" do
      klass = Class.new(Anyway::Config) do
        include Docuconf::Anyway
        config_name :badovl
        attr_config port: 80
        describe :port, "Listen port", config_key: "a.b.c.d.e.f.g.h.i"
        text_file :note, path: "/etc/badovl/shared/note.txt", description: "A text note"
        config_overlay :Platform, path: "/etc/badovl/x.json", format: :json, reload: :sometimes, description: "abc"
        config_overlay :reserved, path: "/app/overlay.yml"
        config_overlay :shared, path: "/etc/badovl/shared/overlay.yml"
        config_overlay :relative, path: "etc/overlay.yml"
      end
      expect { klass.docuconf_declaration }.to raise_error(Docuconf::Anyway::DeclarationError) { |e|
        expect(e.problems).to include(
          a_string_including("overlay Platform: name must be a DNS label"),
          "overlay Platform: description must be at least 5 characters",
          "overlay Platform: format must be yaml; anyway_config layers YAML config files",
          "overlay Platform: reload must be restart or watch",
          a_string_including("overlay reserved: mount directory /app is reserved"),
          a_string_including("overlay shared: shares mount directory /etc/badovl/shared with file note"),
          a_string_including("overlay relative: path \"etc/overlay.yml\" must be absolute"),
          a_string_including("BADOVL_PORT: configKey \"a.b.c.d.e.f.g.h.i\" must be at most 8")
        )
      }
    end

    it "refuses an overlay in the app's own directory or its config directory" do
      root = Anyway::Settings.app_root.to_s
      [File.join(root, "overlay.yml"), File.join(root, "config", "overlay.yml")].each do |path|
        klass = Class.new(Anyway::Config) do
          include Docuconf::Anyway
          config_name :ownovl
          attr_config port: 80
          describe :port, "Listen port"
          config_overlay :platform, path: path
        end
        with_env("DOCUCONF_FILE_ROOT" => nil, "OWNOVL_CONF" => nil) do
          expect { klass.new }.to raise_error(Docuconf::Anyway::DeclarationError, /in the app's own directory/)
        end
      end
    end
  end

  describe "export" do
    it "exports the overlay and a configKey for every variable, and passes cue vet" do
      data = Docuconf::Anyway::Exporter.new(name: "ovl", classes: [ovl_class(reload: :watch)], profiles: false).contract
      expect(data["overlays"]).to eq(
        "platform" => {
          "format" => "yaml", "description" => "Platform settings", "path" => "/etc/ovl/overlay/ovl.yml",
          "keySeparator" => ".", "reload" => "watch"
        }
      )
      expect(data["vars"].transform_values { |v| v["configKey"] }).to eq(
        "OVL_HOSTS" => "ovl.hosts", "OVL_LOG_LEVEL" => "ovl.log_level", "OVL_PORT" => "ovl.port",
        "OVL_TIMEOUT" => "ovl.timeout", "OVL_TOKEN" => "ovl.token"
      )
      require_cue!
      ok, out = cue_vet(Docuconf::Anyway.export(name: "ovl", classes: [ovl_class], profiles: false))
      expect(ok).to be(true), out
    end

    it "rejects an overlay declared differently by two classes, or sharing a file input's directory" do
      a = ovl_class
      b = Class.new(Anyway::Config) do
        include Docuconf::Anyway
        config_name :other
        attr_config port: 80
        describe :port, "Listen port"
        config_overlay :platform, path: "/etc/other/overlay/other.yml"
        text_file :note, path: "/etc/ovl/overlay/note.txt", description: "A text note"
      end
      allow(a).to receive(:name).and_return("A")
      allow(b).to receive(:name).and_return("B")
      expect { Docuconf::Anyway::Exporter.new(name: "x", classes: [a, b], profiles: false).contract }
        .to raise_error(Docuconf::Anyway::DeclarationError) { |e|
          expect(e.problems).to include(
            "overlay platform is declared differently by B",
            a_string_including("file note: shares mount directory /etc/ovl/overlay").or(
              a_string_including("overlay platform: shares mount directory /etc/ovl/overlay")
            )
          )
        }
    end
  end

  describe "reload: :watch" do
    it "applies a changed overlay, and keeps the old values when the new ones are invalid" do
      in_app(overlay: "ovl:\n  port: 82\n") do |root|
        c = ovl_class(reload: :watch).new
        watcher = Docuconf::Anyway::Watcher.new(c, [], overlays: c.class.docuconf_declaration.overlays)
        seen = []
        c.on_overlay_change { |cfg| seen << cfg.port }

        write_file(root, OVERLAY, "ovl:\n  port: 9090\n  log_level: error\n")
        expect(watcher.poll).to eq [:"overlay:platform"]
        expect([c.port, c.log_level]).to eq [9090, "error"]
        expect(seen).to eq [9090]

        expect {
          write_file(root, OVERLAY, "ovl:\n  port: 0\n# invalid, and a different size\n")
          expect(watcher.poll).to eq []
        }.to output(/reload of overlay platform rejected.*OVL_PORT \[out_of_range\]/).to_stderr
        expect(c.port).to eq 9090
        expect(File.exist?(File.join(root, "termination-log"))).to be false
        status = c.docuconf_reload_status(:"overlay:platform")
        expect(status.generation).to eq 2
        expect(status.last_rejected.to_h).to include(input: "platform", codes: [:out_of_range])

        File.delete(File.join(root, OVERLAY))
        expect(watcher.poll).to eq [:"overlay:platform"]
        expect([c.port, c.log_level]).to eq [80, "info"]
        expect(c.docuconf_reload_status(:"overlay:platform")).to have_attributes(generation: 3, last_rejected: nil)
        expect(seen).to eq [9090, 80]
      end
    end

    it "notices a Kubernetes-style ..data symlink swap, and the environment still wins" do
      in_app(env: {"OVL_LOG_LEVEL" => "debug", "DOCUCONF_TERMINATION_LOG" => nil}) do |root|
        dir = File.join(root, File.dirname(OVERLAY))
        FileUtils.mkdir_p(File.join(dir, "..2024_01"))
        File.write(File.join(dir, "..2024_01/ovl.yml"), "ovl:\n  port: 1\n  log_level: warn\n")
        File.symlink("..2024_01", File.join(dir, "..data"))
        File.symlink("..data/ovl.yml", File.join(dir, "ovl.yml"))
        c = ovl_class(reload: :watch).new
        expect([c.port, c.log_level]).to eq [1, "debug"]
        watcher = Docuconf::Anyway::Watcher.new(c, [], overlays: c.class.docuconf_declaration.overlays)

        FileUtils.mkdir_p(File.join(dir, "..2024_02"))
        File.write(File.join(dir, "..2024_02/ovl.yml"), "ovl:\n  port: 2\n  log_level: warn\n")
        File.unlink(File.join(dir, "..data"))
        File.symlink("..2024_02", File.join(dir, "..data"))
        expect(watcher.poll).to eq [:"overlay:platform"]
        expect([c.port, c.log_level]).to eq [2, "debug"]
      end
    end

    it "starts a background watcher for a watched overlay" do
      in_app(overlay: "ovl:\n  port: 82\n", env: {"DOCUCONF_WATCH_INTERVAL" => "0.05"}) do |root|
        Docuconf::Anyway.watch_files = true
        c = ovl_class(reload: :watch).new
        expect(c.docuconf_watcher).to be_a(Docuconf::Anyway::Watcher)
        write_file(root, OVERLAY, "ovl:\n  port: 8443\n")
        deadline = Time.now + 5
        sleep 0.05 until c.port == 8443 || Time.now > deadline
        expect(c.port).to eq 8443
      ensure
        c&.docuconf_watcher&.stop
      end
    end

    it "does not watch a reload: :restart overlay" do
      in_app(overlay: "ovl:\n  port: 82\n") do
        Docuconf::Anyway.watch_files = true
        expect(ovl_class.new.docuconf_watcher).to be_nil
      end
    end
  end

  it "loads an overlay rendered by the platform from the exported contract (end to end)" do
    require_cue!
    text = Docuconf::Anyway.export(name: "sample-gateway", classes: [Fixtures::GatewayConfig],
      root: File.expand_path("fixtures", __dir__))
    rendered = cue_render_file(text, package: "sample_gateway", file_name: "gateway.yml", overlays: <<~CUE)
      {
      	platform: {
      		GATEWAY_PORT:            9090
      		GATEWAY_REQUEST_TIMEOUT: "1m30s"
      		GATEWAY_SAMPLE_RATE:     0.5
      		GATEWAY_DEBUG:           true
      		GATEWAY_LOG_LEVEL:       "warn"
      		GATEWAY_WORKER_PORTS: [7000, 7001]
      		GATEWAY_RATE_LIMITS: {perMinute: 60, burst: 10}
      	}
      }
    CUE
    expect(rendered).to include("gateway:\n").and include("request_timeout: PT90S")

    in_gateway do |root|
      write_file(root, "etc/gateway/overlay/gateway.yml", rendered)
      c = Fixtures::GatewayConfig.new
      expect(c.port).to eq 9090
      expect(c.request_timeout).to eq 90
      expect(c.sample_rate).to eq 0.5
      expect(c.debug).to be true
      expect(c.log_level).to eq "warn"
      expect(c.worker_ports).to eq [7000, 7001]
      expect(c.rate_limits).to eq("perMinute" => 60, "burst" => 10)
    end
  end
end
