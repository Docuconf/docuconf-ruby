# frozen_string_literal: true

# A minimal Rails app for spec/railtie_spec.rb, run in a subprocess:
#   ruby spec/rails/app.rb boot|export|precompile ROOT
mode, APP_ROOT = ARGV
begin
  require "rails"
rescue LoadError
  exit 3
end
require "logger"
require "rake"
require "anyway_config"
require "docuconf/anyway"

class TestApp < Rails::Application
  config.root = APP_ROOT
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "x" * 64
end

class ShopConfig < Anyway::Config
  include Docuconf::Anyway

  attr_config :api_key, :token, port: 8080
  describe :port, "HTTP listen port", min: 1, max: 9999
  describe :token, "Token for the payment API", secret: true
  exclude :api_key # a Rails credential
  config_overlay :platform, path: "/etc/shop/overlay/shop.yml"
end

case mode
when "boot"
  begin
    Rails.application.initialize!
    puts "booted port=#{ShopConfig.new.port}"
    puts "loaders=#{Anyway.loaders.keys.join(",")}"
  rescue Docuconf::Anyway::ValidationError => e
    puts e.message
    exit 1
  end
when "boot_raw"
  # As a real app: no rescue, so docuconf decides how a failure looks.
  Rails.application.initialize!
  puts "booted"
when "tooling"
  Rails.application.load_tasks
  Rake::Task.define_task("db:migrate") do
    Rails.application.initialize!
    puts "migrated"
  end
  Rake.application.instance_variable_set(:@top_level_tasks, ["db:migrate"])
  $stderr.reopen($stdout)
  Rake::Task["db:migrate"].invoke
when "generate"
  require "rails/generators"
  Rails.application.initialize!
  Rails.application.load_generators
  FileUtils.mkdir_p(File.join(APP_ROOT, "config/configs"))
  File.write(File.join(APP_ROOT, "config/configs/payments_config.rb"),
    "class PaymentsConfig < Anyway::Config\n  attr_config :api_key, timeout: 5\nend\n")
  load File.join(APP_ROOT, "config/configs/payments_config.rb")
  Rails::Generators.invoke("docuconf:config", ["payments", "--quiet"], destination_root: APP_ROOT)
  Rails::Generators.invoke("docuconf:config", %w[shipping carrier region --quiet], destination_root: APP_ROOT)
  puts File.read(File.join(APP_ROOT, "config/configs/payments_config.rb"))
  puts File.read(File.join(APP_ROOT, "config/configs/shipping_config.rb"))
when "filter"
  Rails.application.initialize!
  f = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  puts f.filter("token" => +"tok_123", "port" => "1").inspect
when "export_stdout"
  Rails.application.load_tasks
  Rake.application.instance_variable_set(:@top_level_tasks, ["docuconf:export"])
  Rake::Task["docuconf:export"].invoke
when "export", "precompile"
  Rails.application.load_tasks
  task = mode == "export" ? "docuconf:export" : "assets:precompile"
  Rake::Task.define_task("assets:precompile" => :environment) { puts "precompiled" } if mode == "precompile"
  Rake.application.instance_variable_set(:@top_level_tasks, [task])
  Rake::Task[task].invoke
end
