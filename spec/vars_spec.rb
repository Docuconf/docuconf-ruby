# frozen_string_literal: true

RSpec.describe "variables at boot" do
  it "loads typed values through anyway_config" do
    in_gateway(
      "GATEWAY_PORT" => "9090", "GATEWAY_SAMPLE_RATE" => "0.5", "GATEWAY_DEBUG" => "TRUE",
      "GATEWAY_REQUEST_TIMEOUT" => "PT1M30S", "GATEWAY_WORKER_PORTS" => "7000,7001",
      "GATEWAY_RATE_LIMITS" => '{"perMinute":60,"burst":10}', "GATEWAY_LOG_LEVEL" => "warn",
      "GATEWAY_GOMEMLIMIT" => "1073741824"
    ) do
      c = Fixtures::GatewayConfig.new
      expect(c.port).to eq 9090
      expect(c.sample_rate).to eq 0.5
      expect(c.debug).to be true
      expect(c.request_timeout).to eq 90
      expect(c.worker_ports).to eq [7000, 7001]
      expect(c.allowed_origins).to eq %w[https://a.example.com https://b.example.com]
      expect(c.rate_limits).to eq("perMinute" => 60, "burst" => 10)
      expect(c.log_level).to eq "warn"
      expect(c.gomemlimit).to eq 1_073_741_824
      expect(c.database_url).to start_with("postgres://")
    end
  end

  it "uses defaults when variables are unset, and treats empty as unset for non-strings" do
    in_gateway("GATEWAY_PORT" => "", "GATEWAY_DEBUG" => "", "GATEWAY_REQUEST_TIMEOUT" => "") do
      c = Fixtures::GatewayConfig.new
      expect(c.port).to eq 8080
      expect(c.debug).to be false
      expect(c.request_timeout).to eq 30
      expect(c.worker_ports).to be_nil
    end
  end

  it "reports a non-integer as invalid_type instead of coercing it" do
    in_gateway("GATEWAY_PORT" => "80a") do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["GATEWAY_PORT", :invalid_type]]
        expect(e.message).to include('GATEWAY_PORT [invalid_type]: "80a" is not an integer')
      }
    end
  end

  it "rejects leading zeros, signs, spaces and values outside int64" do
    ["+5", "007", " 5", "5 ", "1e3", "9223372036854775808"].each do |raw|
      in_gateway("GATEWAY_PORT" => raw) do
        expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
          expect(codes(e)).to eq [["GATEWAY_PORT", :invalid_type]]
        }
      end
    end
  end

  it "reports a missing required variable" do
    in_gateway("GATEWAY_REGION" => nil) do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["GATEWAY_REGION", :missing_required]]
      }
    end
  end

  it "treats an empty required list as missing" do
    in_gateway("GATEWAY_ALLOWED_ORIGINS" => "") do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["GATEWAY_ALLOWED_ORIGINS", :missing_required]]
      }
    end
  end

  it "treats an empty string as present for string variables" do
    in_gateway("GATEWAY_REGION" => "") do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to contain_exactly(["GATEWAY_REGION", :out_of_range], ["GATEWAY_REGION", :pattern_mismatch])
      }
    end
  end

  it "matches patterns against the whole text, not one line (RE2 semantics)" do
    in_gateway("GATEWAY_REGION" => "eu-west-1\nevil") do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["GATEWAY_REGION", :pattern_mismatch]]
      }
    end
  end

  it "never trims values" do
    in_gateway("GATEWAY_LOG_LEVEL" => "info ") do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["GATEWAY_LOG_LEVEL", :not_in_enum]]
      }
    end
  end

  it "reports every violation together, with stable codes" do
    in_gateway(
      "GATEWAY_PORT" => "70000", "GATEWAY_SAMPLE_RATE" => "NaN", "GATEWAY_DEBUG" => "maybe",
      "GATEWAY_REQUEST_TIMEOUT" => "PT10M", "GATEWAY_LOG_LEVEL" => "trace",
      "GATEWAY_PUBLIC_URL" => "http://gateway.example.com", "GATEWAY_ALLOWED_ORIGINS" => (1..11).to_a.join(","),
      "GATEWAY_WORKER_PORTS" => "1,x", "GATEWAY_RATE_LIMITS" => '{"perMinute":0}', "GATEWAY_REGION" => nil,
      "GATEWAY_GOMEMLIMIT" => "0"
    ) do
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to contain_exactly(
          ["GATEWAY_PORT", :out_of_range],
          ["GATEWAY_SAMPLE_RATE", :invalid_type],
          ["GATEWAY_DEBUG", :invalid_type],
          ["GATEWAY_REQUEST_TIMEOUT", :out_of_range],
          ["GATEWAY_LOG_LEVEL", :not_in_enum],
          ["GATEWAY_PUBLIC_URL", :invalid_scheme],
          ["GATEWAY_ALLOWED_ORIGINS", :too_many_items],
          ["GATEWAY_WORKER_PORTS", :invalid_type],
          ["GATEWAY_RATE_LIMITS", :schema_mismatch],
          ["GATEWAY_REGION", :missing_required],
          ["GATEWAY_GOMEMLIMIT", :out_of_range]
        )
        expect(e.message).to start_with("docuconf: 11 configuration problems:")
      }
    end
  end

  it "reports too few list items" do
    klass = Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :lists
      attr_config :hosts
      coerce_types hosts: {type: :string, array: true}
      describe :hosts, "Hosts to contact", min_items: 2
    end
    with_env("LISTS_HOSTS" => "a.internal") do
      expect { klass.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["LISTS_HOSTS", :too_few_items]]
      }
    end
  end

  it "never prints secret values" do
    secret = "mysql://app:hunter2-very-secret@db/x"
    in_gateway("GATEWAY_DATABASE_URL" => secret, "GATEWAY_KEYSTORE_PASSWORD" => "") do |root|
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to include(["GATEWAY_DATABASE_URL", :invalid_scheme], ["GATEWAY_KEYSTORE_PASSWORD", :out_of_range])
        expect(e.message).not_to include("hunter2")
        expect(e.message).not_to include("mysql")
        expect(File.read(File.join(root, "termination-log"))).not_to include("hunter2")
      }
    end
  end

  it "never prints a secret that fails to parse" do
    klass = Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :sec
      attr_config :pin
      coerce_types pin: :integer
      describe :pin, "Numeric PIN code"
      secret :pin
    end
    with_env("SEC_PIN" => "12x45-topsecret") do
      expect { klass.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["SEC_PIN", :invalid_type]]
        expect(e.message).not_to include("topsecret")
      }
    end
  end

  it "writes violations to the termination log" do
    in_gateway("GATEWAY_PORT" => "0") do |root|
      expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError)
      expect(File.read(File.join(root, "termination-log"))).to include("GATEWAY_PORT [out_of_range]")
    end
  end

  it "is an anyway_config ValidationError" do
    expect(Docuconf::Anyway::ValidationError.ancestors).to include(Anyway::Config::ValidationError)
  end

  it "skips validation with DOCUCONF_SKIP_VALIDATION or anyway's suppress_required_validations" do
    in_gateway("GATEWAY_PORT" => "x", "DOCUCONF_SKIP_VALIDATION" => "1") do
      expect { Fixtures::GatewayConfig.new }.not_to raise_error
    end
    in_gateway("GATEWAY_REGION" => nil) do
      Anyway::Settings.suppress_required_validations = true
      expect { Fixtures::GatewayConfig.new }.not_to raise_error
    ensure
      Anyway::Settings.suppress_required_validations = false
    end
  end

  it "still checks required attributes that are excluded from the contract" do
    klass = Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :creds
      attr_config :api_key, port: 1
      required :api_key
      exclude :api_key
      describe :port, "Listen port"
    end
    with_env("CREDS_API_KEY" => nil) do
      expect { klass.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
        expect(codes(e)).to eq [["creds.api_key", :missing_required]]
      }
    end
  end

  it "accepts programmatic overrides and checks them" do
    in_gateway do
      expect(Fixtures::GatewayConfig.new(port: 1234).port).to eq 1234
      expect { Fixtures::GatewayConfig.new(port: 0) }.to raise_error(Docuconf::Anyway::ValidationError)
    end
  end

  context "with YAML from anyway_config" do
    around do |ex|
      Dir.mktmpdir do |dir|
        old_path = Anyway::Settings.default_config_path
        old_env = Anyway::Settings.current_environment
        Anyway::Settings.default_config_path = dir
        Anyway::Settings.current_environment = "production"
        @yaml_dir = dir
        ex.run
      ensure
        Anyway::Settings.default_config_path = old_path
        Anyway::Settings.current_environment = old_env
      end
    end

    it "validates values from the YAML file, and the environment overrides them" do
      File.write(File.join(@yaml_dir, "gateway.yml"), "production:\n  port: 99999\n  log_level: warn\n")
      in_gateway do
        expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
          expect(codes(e)).to eq [["GATEWAY_PORT", :out_of_range]]
        }
      end
      in_gateway("GATEWAY_PORT" => "8443") do
        c = Fixtures::GatewayConfig.new
        expect([c.port, c.log_level]).to eq [8443, "warn"]
      end
    end

    it "reports a YAML value of the wrong type" do
      File.write(File.join(@yaml_dir, "gateway.yml"), "production:\n  port: eighty\n")
      in_gateway do
        expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
          expect(codes(e)).to eq [["GATEWAY_PORT", :invalid_type]]
        }
      end
    end
  end

  it "warns about variables that look like feature flags" do
    klass = Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :ff
      env_prefix ""
      attr_config enable_new_checkout: false
      describe :enable_new_checkout, "New checkout flow"
    end
    expect { klass.docuconf_declaration }.to output(/ENABLE_NEW_CHECKOUT looks like a feature flag/).to_stderr
  end

  it "parses durations as ISO 8601 and exposes ActiveSupport::Duration when it is loaded" do
    skip "ActiveSupport is not installed" unless begin
      require "active_support"
      require "active_support/core_ext/integer/time"
      true
    rescue LoadError
      false
    end

    in_gateway("GATEWAY_REQUEST_TIMEOUT" => "PT45S") do
      c = Fixtures::GatewayConfig.new
      expect(c.request_timeout).to be_a(ActiveSupport::Duration)
      expect(c.request_timeout).to eq 45.seconds
    end
  end
end
