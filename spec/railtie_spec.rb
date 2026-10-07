# frozen_string_literal: true

require "open3"

RSpec.describe "Rails integration" do
  APP = File.expand_path("rails/app.rb", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # Extra string keyword arguments are environment variables.
  def run_app(mode, env = {}, **opts)
    overlay = opts.delete(:overlay)
    env = env.merge(opts)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/shop.yml"), "production:\n  port: 443\ndevelopment:\n  port: 3000\n")
      if overlay
        FileUtils.mkdir_p(File.join(root, "etc/shop/overlay"))
        File.write(File.join(root, "etc/shop/overlay/shop.yml"), overlay)
      end
      env = {"RAILS_ENV" => "production", "SHOP_PORT" => nil, "DOCUCONF_FILE_ROOT" => root}.merge(env)
      out, status = Open3.capture2e(env,
        RbConfig.ruby, "-I", LIB, APP, mode, root)
      skip "railties is not installed (bundle with the rails group)" if status.exitstatus == 3
      [out, status]
    end
  end

  it "validates every config at boot" do
    out, status = run_app("boot", "SHOP_PORT" => "10000")
    expect(status.exitstatus).to eq(1), out
    expect(out).to include("SHOP_PORT [out_of_range]: 10000 is above max 9999")
  end

  it "boots with values from the per-environment YAML" do
    out, status = run_app("boot")
    expect(status).to be_success, out
    expect(out).to include("booted port=443")
  end

  it "layers the overlay after the YAML and credentials, before the environment" do
    out, status = run_app("boot", overlay: "shop:\n  port: 8443\n")
    expect(status).to be_success, out
    expect(out).to include("booted port=8443")
    loaders = out[/^loaders=(.*)$/, 1].split(",")
    expect(loaders.last(2)).to eq %w[docuconf_overlay env]
    expect(loaders.index("credentials")).to be < loaders.index("docuconf_overlay") if loaders.include?("credentials")

    out, status = run_app("boot", {"SHOP_PORT" => "9000"}, overlay: "shop:\n  port: 8443\n")
    expect(status).to be_success, out
    expect(out).to include("booted port=9000")
  end

  it "exports the contract with rails docuconf:export, without a valid environment" do
    out, status = run_app("export", "SHOP_PORT" => "not-a-number")
    expect(status).to be_success, out
    expect(out).to include("package test_app")
    expect(out).to include("SHOP_PORT: {")
    expect(out).to include("selector: \"RAILS_ENV\"")
    expect(out).not_to include("SHOP_API_KEY")
  end

  it "exits 1 with the problems and no backtrace when the app boots misconfigured" do
    out, status = run_app("boot_raw", "SHOP_PORT" => "10000")
    expect(status.exitstatus).to eq(1), out
    expect(out).to eq "docuconf: 1 configuration problem:\n  - SHOP_PORT [out_of_range]: 10000 is above max 9999\n"
  end

  it "only warns during tooling commands such as db:migrate" do
    out, status = run_app("tooling", "SHOP_PORT" => "10000")
    expect(status).to be_success, out
    expect(out).to include("SHOP_PORT [out_of_range]").and include("continuing, since this is a tooling command")
    expect(out).to include("migrated")
  end

  it "exports the same contract in every RAILS_ENV, without development and test sections" do
    outs = %w[development test production].map do |env|
      out, status = run_app("export_stdout", "RAILS_ENV" => env)
      expect(status).to be_success, out
      out
    end
    expect(outs.uniq.size).to eq 1
    expect(outs.first).to include("production: {").and include("SHOP_PORT: 443")
    expect(outs.first).not_to include("development: {")
  end

  it "takes the CLI's options in docuconf:export" do
    out, status = run_app("export_stdout", "PROFILES" => "development,production", "DEFAULT_PROFILE" => "production",
      "PACKAGE" => "shop_pkg", "NAME" => "shop")
    expect(status).to be_success, out
    expect(out).to include("package shop_pkg").and include("development: {").and include('default:  "production"')

    out, status = run_app("export_stdout", "NO_PROFILES" => "1")
    expect(status).to be_success, out
    expect(out).not_to include("profiles")
  end

  it "rails g docuconf:config adds the include and describe stubs" do
    out, status = run_app("generate")
    expect(status).to be_success, out
    expect(out).to include(<<~RUBY)
      class PaymentsConfig < Anyway::Config
        include Docuconf::Anyway

        attr_config :api_key, timeout: 5

        describe :api_key, "" # TODO: what is api_key for? (at least 5 characters)
        describe :timeout, "" # TODO: what is timeout for? (at least 5 characters)
      end
    RUBY
    expect(out).to include("class ShippingConfig < Anyway::Config\n  include Docuconf::Anyway\n\n  attr_config :carrier, :region\n")
    expect(out).to include('describe :region, "" # TODO')
  end

  it "adds secrets to filter_parameters" do
    out, status = run_app("filter")
    expect(status).to be_success, out
    expect(out).to include('{"token"=>"[FILTERED]", "port"=>"1"}').or include('{"token" => "[FILTERED]", "port" => "1"}')
  end

  it "skips validation during assets:precompile" do
    out, status = run_app("precompile", "SHOP_PORT" => "10000")
    expect(status).to be_success, out
    expect(out).to include("precompiled")
  end
end
