# frozen_string_literal: true

require "open3"

RSpec.describe "Rails integration" do
  APP = File.expand_path("rails/app.rb", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  def run_app(mode, env = {})
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/shop.yml"), "production:\n  port: 443\ndevelopment:\n  port: 3000\n")
      out, status = Open3.capture2e({"RAILS_ENV" => "production", "SHOP_PORT" => nil}.merge(env),
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

  it "exports the contract with rails docuconf:export, without a valid environment" do
    out, status = run_app("export", "SHOP_PORT" => "not-a-number")
    expect(status).to be_success, out
    expect(out).to include("package test_app")
    expect(out).to include("SHOP_PORT: {")
    expect(out).to include("selector: \"RAILS_ENV\"")
    expect(out).not_to include("SHOP_API_KEY")
  end

  it "skips validation during assets:precompile" do
    out, status = run_app("precompile", "SHOP_PORT" => "10000")
    expect(status).to be_success, out
    expect(out).to include("precompiled")
  end
end
