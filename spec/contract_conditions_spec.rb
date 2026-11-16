# frozen_string_literal: true

# Contract-first mode: requiredIf (SPEC §4.2.1), roles (SPEC §4.9) and
# includes (SPEC §4.8).
RSpec.describe "contract-first requiredIf, roles and includes" do
  def contract(vars, **extra)
    {
      "apiVersion" => "docuconf.dev/v1alpha1", "kind" => "ConfigContract",
      "metadata" => {"name" => "svc", "generator" => {"language" => "go", "sdk" => "x", "version" => "1"}},
      "vars" => vars
    }.merge(extra.transform_keys(&:to_s))
  end

  def parse(vars, **extra) = Docuconf::Anyway::Contract.parse(contract(vars, **extra))

  def problems(vars, **extra)
    parse(vars, **extra)
    raise "expected a DeclarationError"
  rescue Docuconf::Anyway::DeclarationError => e
    e.problems
  end

  def violations(vars, env, **extra)
    parse(vars, **extra).load(env, termination_log: false, watch: false)
    raise "expected a ValidationError"
  rescue Docuconf::Anyway::ValidationError => e
    e.violations.map { |v| [v.input, v.code, v.message] }
  end

  let(:tls_vars) do
    {
      "TLS_ENABLED" => {"type" => "bool", "description" => "Serve TLS", "default" => false},
      "LOG_FORMAT" => {"type" => "enum", "description" => "Log format", "values" => %w[text json], "default" => "text"},
      "TLS_CLIENT_CA_SUBJECT" => {"type" => "string", "description" => "Client CA subject",
                                  "requiredIf" => {"TLS_ENABLED" => true}},
      "LOG_SCHEMA_URL" => {"type" => "url", "description" => "Log schema", "requiredIf" => {"LOG_FORMAT" => "json"}}
    }
  end

  describe "requiredIf at load" do
    it "is optional while the condition does not hold" do
      values = parse(tls_vars).load({}, termination_log: false, watch: false)
      expect(values["TLS_CLIENT_CA_SUBJECT"]).to be_nil
      expect(values["LOG_SCHEMA_URL"]).to be_nil
    end

    it "says which condition requires a missing variable, the value as JSON" do
      got = violations(tls_vars, {"TLS_ENABLED" => "true", "LOG_FORMAT" => "json"})
      expect(got).to contain_exactly(
        ["TLS_CLIENT_CA_SUBJECT", :missing_required, "is required when TLS_ENABLED is true"],
        ["LOG_SCHEMA_URL", :missing_required, 'is required when LOG_FORMAT is "json"']
      )
    end

    it "holds on a profile default" do
      got = violations(tls_vars.merge("APP_ENV" => {"type" => "string", "description" => "Profile"}),
        {"APP_ENV" => "production"},
        profiles: {"selector" => "APP_ENV", "default" => "development",
                   "defaults" => {"production" => {"TLS_ENABLED" => true}}})
      expect(got).to eq([["TLS_CLIENT_CA_SUBJECT", :missing_required, "is required when TLS_ENABLED is true"]])
    end

    it "makes nothing required when the condition variable has a violation of its own" do
      got = violations(tls_vars, {"TLS_ENABLED" => "yes"})
      expect(got.map { |i, c, _| [i, c] }).to eq([["TLS_ENABLED", :invalid_type]])
    end

    it "keeps a bool apart from an int" do
      vars = {"MODE" => {"type" => "int", "description" => "Mode"},
              "EXTRA" => {"type" => "string", "description" => "Extra", "requiredIf" => {"MODE" => 1}}}
      expect(violations(vars, {"MODE" => "1"})).to eq([["EXTRA", :missing_required, "is required when MODE is 1"]])
      expect(parse(vars).load({"MODE" => "2"}, termination_log: false, watch: false)["EXTRA"]).to be_nil
    end

    it "reports a missing file whose condition holds as file_missing, with the condition" do
      Dir.mktmpdir do |root|
        files = {"allowlist" => {"type" => "text", "description" => "Allowed callers", "path" => "/etc/svc/allow/list.txt",
                                 "requiredIf" => {"TLS_ENABLED" => true}}}
        env = {"DOCUCONF_FILE_ROOT" => root}
        expect(parse(tls_vars, files: files).load(env, termination_log: false, watch: false)["allowlist"]).to be_nil
        got = violations(tls_vars, env.merge("TLS_ENABLED" => "true", "TLS_CLIENT_CA_SUBJECT" => "CN=x"), files: files)
        expect(got.size).to eq 1
        input, code, message = got.first
        expect([input, code]).to eq(["allowlist", :file_missing])
        expect(message).to end_with("does not exist, and is required when TLS_ENABLED is true")
      end
    end
  end

  describe "requiredIf in the contract" do
    def with_condition(cond, **entry)
      tls_vars.merge("EXTRA" => {"type" => "string", "description" => "Extra", "requiredIf" => cond}.merge(entry.transform_keys(&:to_s)))
    end

    it "must name one variable and a string, integer or boolean value" do
      expect(problems(with_condition({}))).to include(match(/EXTRA: requiredIf must name one variable/))
      expect(problems(with_condition({"TLS_ENABLED" => true, "LOG_FORMAT" => "json"})))
        .to include(match(/EXTRA: requiredIf must name one variable/))
      expect(problems(with_condition({"TLS_ENABLED" => 1.5}))).to include(match(/string, integer or boolean value/))
      expect(problems(with_condition({"TLS_ENABLED" => nil}))).to include(match(/string, integer or boolean value/))
    end

    it "must name another declared variable" do
      expect(problems(with_condition({"NOPE" => true}))).to include("EXTRA: requiredIf must name another declared variable, not NOPE")
      expect(problems(with_condition({"EXTRA" => "x"}))).to include("EXTRA: requiredIf must name another declared variable, not EXTRA")
    end

    it "rejects a secret or non-plain condition variable" do
      vars = with_condition({"TOKEN" => "x"}).merge("TOKEN" => {"type" => "string", "description" => "Token", "secret" => true})
      expect(problems(vars)).to include(match(/requiredIf names TOKEN, which is not a plain/))
      vars = with_condition({"RATE" => 1}).merge("RATE" => {"type" => "float", "description" => "Rate"})
      expect(problems(vars)).to include(match(/requiredIf names RATE, which is not a plain/))
    end

    it "rejects a value the condition variable cannot hold" do
      expect(problems(with_condition({"TLS_ENABLED" => 1}))).to include("EXTRA: requiredIf: TLS_ENABLED is 1 is not a value TLS_ENABLED can have")
      expect(problems(with_condition({"TLS_ENABLED" => "true"}))).to include(match(/TLS_ENABLED is "true" is not a value/))
      expect(problems(with_condition({"LOG_FORMAT" => "xml"}))).to include(match(/LOG_FORMAT is "xml" is not a value LOG_FORMAT can have: /))
    end

    it "rejects a required, defaulted or deprecated input" do
      expect(problems(with_condition({"TLS_ENABLED" => true}, required: true)))
        .to include("EXTRA: an input with requiredIf cannot be required or have a default")
      expect(problems(with_condition({"TLS_ENABLED" => true}, default: "x")))
        .to include("EXTRA: an input with requiredIf cannot be required or have a default")
      expect(problems(with_condition({"TLS_ENABLED" => true}, deprecated: {"message" => "gone"})))
        .to include(match(/EXTRA: a conditionally required input cannot be deprecated/))
    end

    it "is checked on file inputs too" do
      files = {"allowlist" => {"type" => "text", "description" => "Allowed", "path" => "/etc/svc/allow/list.txt",
                               "requiredIf" => {"NOPE" => true}}}
      expect(problems(tls_vars, files: files)).to include("file allowlist: requiredIf must name another declared variable, not NOPE")
    end

    it "is exposed on the declarations" do
      cond = parse(tls_vars).var("LOG_SCHEMA_URL").required_if
      expect([cond.var, cond.value, cond.to_s]).to eq(["LOG_FORMAT", "json", 'LOG_FORMAT is "json"'])
    end
  end

  describe "roles" do
    let(:role_var) do
      {"type" => "enum", "description" => "The role this workload runs", "required" => true, "values" => %w[web worker]}
    end
    let(:role_vars) do
      {
        "DOCUCONF_ROLE" => role_var,
        "ALLOWED_ORIGINS" => {"type" => "list", "items" => "string", "description" => "Origins", "required" => true,
                              "roles" => ["web"]},
        "QUEUES" => {"type" => "list", "items" => "string", "description" => "Queues", "required" => true,
                     "roles" => ["worker"]},
        "DATABASE_URL" => {"type" => "string", "description" => "Database", "required" => true}
      }
    end

    it "requires only the inputs the role uses" do
      c = parse(role_vars, roles: %w[web worker])
      expect(c.roles).to eq(%w[web worker])
      expect(c.role({"DOCUCONF_ROLE" => "worker"})).to eq "worker"
      values = c.load({"DOCUCONF_ROLE" => "worker", "QUEUES" => "a,b", "DATABASE_URL" => "db"},
        termination_log: false, watch: false)
      expect(values["QUEUES"]).to eq(%w[a b])
      expect(values["ALLOWED_ORIGINS"]).to be_nil
      expect(violations(role_vars, {"DOCUCONF_ROLE" => "web", "DATABASE_URL" => "db"}, roles: %w[web worker]))
        .to eq([["ALLOWED_ORIGINS", :missing_required, "required, and not set"]])
    end

    it "with no valid role, reports the role and requires no role-specific input" do
      expect(violations(role_vars, {"DATABASE_URL" => "db"}, roles: %w[web worker]).map { |i, c, _| [i, c] })
        .to eq([["DOCUCONF_ROLE", :missing_required]])
      expect(violations(role_vars, {"DOCUCONF_ROLE" => "cron", "DATABASE_URL" => "db"}, roles: %w[web worker])
        .map { |i, c, _| [i, c] }).to eq([["DOCUCONF_ROLE", :not_in_enum]])
      expect(parse(role_vars, roles: %w[web worker]).role({"DOCUCONF_ROLE" => "cron"})).to be_nil
    end

    it "makes a required file of another role optional" do
      Dir.mktmpdir do |root|
        files = {"robots" => {"type" => "text", "description" => "robots.txt", "path" => "/etc/web/robots.txt",
                              "required" => true, "roles" => ["web"]}}
        c = parse(role_vars, roles: %w[web worker], files: files)
        env = {"DOCUCONF_FILE_ROOT" => root, "DATABASE_URL" => "db"}
        expect(c.load(env.merge("DOCUCONF_ROLE" => "worker", "QUEUES" => "a"), termination_log: false, watch: false)["robots"])
          .to be_nil
        expect(violations(role_vars, env.merge("DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "x"), roles: %w[web worker],
          files: files).map { |i, c, _| [i, c] }).to eq([["robots", :file_missing]])
      end
    end

    it "does not require a requiredIf input outside its role" do
      vars = role_vars.merge(
        "TLS_ENABLED" => {"type" => "bool", "description" => "TLS", "default" => true},
        "CA_SUBJECT" => {"type" => "string", "description" => "CA", "requiredIf" => {"TLS_ENABLED" => true}, "roles" => ["web"]}
      )
      env = {"DOCUCONF_ROLE" => "worker", "QUEUES" => "a", "DATABASE_URL" => "db"}
      expect(parse(vars, roles: %w[web worker]).load(env, termination_log: false, watch: false)["CA_SUBJECT"]).to be_nil
      expect(violations(vars, env.merge("DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "x"), roles: %w[web worker]))
        .to eq([["CA_SUBJECT", :missing_required, "is required when TLS_ENABLED is true"]])
    end

    it "rejects malformed roles" do
      expect(problems(role_vars, roles: [])).to include("roles must be a list of at least one role name")
      expect(problems(role_vars, roles: "web")).to include("roles must be a list of at least one role name")
      expect(problems(role_vars, roles: %w[web Web worker])).to include('role "Web" must be a DNS label')
      expect(problems(role_vars, roles: %w[web worker web])).to include("role web is listed twice")
      vars = role_vars.merge("QUEUES" => role_vars["QUEUES"].merge("roles" => []))
      expect(problems(vars, roles: %w[web worker])).to include("QUEUES: roles must be a list of at least one role name")
    end

    it "rejects input roles outside the contract's, or with none" do
      vars = role_vars.merge("QUEUES" => role_vars["QUEUES"].merge("roles" => %w[worker cron]))
      expect(problems(vars, roles: %w[web worker])).to include("QUEUES: role cron is not one of the contract's roles, web, worker")
      no_roles = role_vars.reject { |k, _| k == "DOCUCONF_ROLE" }
      expect(problems(no_roles)).to include("ALLOWED_ORIGINS: has roles, but the contract declares none")
      files = {"robots" => {"type" => "text", "description" => "robots.txt", "path" => "/etc/web/robots.txt", "roles" => ["web"]}}
      expect(problems({}, files: files)).to include("file robots: has roles, but the contract declares none")
    end

    it "requires DOCUCONF_ROLE as a required enum of exactly the roles, used by every role" do
      message = "DOCUCONF_ROLE: a contract with roles declares it as a required enum whose values are the roles, " \
        "web, worker, used by every role"
      [
        role_vars.reject { |k, _| k == "DOCUCONF_ROLE" },
        role_vars.merge("DOCUCONF_ROLE" => role_var.merge("required" => false)),
        role_vars.merge("DOCUCONF_ROLE" => role_var.merge("values" => %w[worker web])),
        role_vars.merge("DOCUCONF_ROLE" => role_var.merge("roles" => ["web"])),
        role_vars.merge("DOCUCONF_ROLE" => {"type" => "string", "description" => "Role", "required" => true})
      ].each { |vars| expect(problems(vars, roles: %w[web worker])).to include(message) }
    end
  end

  describe "includes" do
    it "reads and exposes the fragments" do
      expect(parse(tls_vars, includes: %w[go-runtime@1 otel@1]).includes).to eq(%w[go-runtime@1 otel@1])
      expect(parse(tls_vars).includes).to eq([])
    end

    it "rejects malformed includes" do
      expect(problems(tls_vars, includes: "otel@1")).to include("includes must be a list of fragment names, such as otel@1")
      expect(problems(tls_vars, includes: %w[otel])).to include('includes: "otel" is not a fragment name, name@major')
      expect(problems(tls_vars, includes: %w[otel@1 otel@1])).to include("includes: otel@1 is listed twice")
    end
  end
end
