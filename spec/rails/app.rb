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

  attr_config :api_key, port: 8080
  describe :port, "HTTP listen port", min: 1, max: 9999
  exclude :api_key # a Rails credential
end

case mode
when "boot"
  begin
    Rails.application.initialize!
    puts "booted port=#{ShopConfig.new.port}"
  rescue Docuconf::Anyway::ValidationError => e
    puts e.message
    exit 1
  end
when "export", "precompile"
  Rails.application.load_tasks
  task = mode == "export" ? "docuconf:export" : "assets:precompile"
  Rake::Task.define_task("assets:precompile" => :environment) { puts "precompiled" } if mode == "precompile"
  Rake.application.instance_variable_set(:@top_level_tasks, [task])
  Rake::Task[task].invoke
end
