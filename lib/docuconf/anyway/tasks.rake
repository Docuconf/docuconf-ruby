# frozen_string_literal: true

namespace :docuconf do
  task :export_mode do
    Docuconf::Anyway.export_mode = true
  end

  desc "Export the docuconf contract. NAME=service (default: the app name) OUT=contract.cue APP_VERSION=sha"
  task export: %i[export_mode environment] do
    Docuconf::Anyway::Railtie.eager_load_configs
    app = Rails.application.class
    name = ENV["NAME"] || (app.module_parent_name || app.name.delete_suffix("Application")).underscore.dasherize
    text = Docuconf::Anyway.export(name: name, app_version: ENV["APP_VERSION"], root: Rails.root)
    if ENV["OUT"]
      File.write(ENV["OUT"], text)
      warn "docuconf: wrote #{ENV["OUT"]}"
    else
      $stdout.print text
    end
  end

  desc "Validate the current environment and files against every docuconf config"
  task check: :environment do
    Docuconf::Anyway::Railtie.eager_load_configs
    Docuconf::Anyway.validate_all!
    puts "docuconf: configuration is valid"
  rescue Docuconf::Anyway::ValidationError => e
    warn e.message
    exit 1
  end
end
