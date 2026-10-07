# frozen_string_literal: true

namespace :docuconf do
  task :export_mode do
    Docuconf::Anyway.export_mode = true
  end

  desc "Export the docuconf contract. NAME=service (default: the app name) OUT=contract.cue APP_VERSION=sha " \
    "PACKAGE=cue_pkg CLASS=A,B PROFILES=production,staging NO_PROFILES=1 DEFAULT_PROFILE=production " \
    "ALLOW_EMPTY=1 CHECK=1"
  task export: %i[export_mode environment] do
    Docuconf::Anyway::Railtie.eager_load_configs
    settings = Rails.application.config.docuconf
    app = Rails.application.class
    name = ENV["NAME"] || (app.module_parent_name || app.name.delete_suffix("Application")).underscore.dasherize
    list = ->(v) { v.to_s.split(",").map(&:strip).reject(&:empty?) }
    flag = ->(v) { %w[1 true yes].include?(v.to_s.downcase) }

    options = {name: name, app_version: ENV["APP_VERSION"], root: Rails.root, package: ENV["PACKAGE"]}
    options[:classes] = list.call(ENV["CLASS"]).map { |n| Object.const_get(n) } if ENV["CLASS"]
    options[:profiles] = false if flag.call(ENV["NO_PROFILES"])
    profiles = ENV["PROFILES"] ? list.call(ENV["PROFILES"]) : settings.export_profiles
    options[:export_profiles] = Array(profiles).map(&:to_s) if profiles
    default_profile = ENV["DEFAULT_PROFILE"] || settings.default_profile
    options[:default_profile] = default_profile.to_s if default_profile
    options[:allow_empty] = true if flag.call(ENV["ALLOW_EMPTY"])

    begin
      text = Docuconf::Anyway.export(**options, warn: ->(m) { warn "docuconf: #{m}" })
    rescue Docuconf::Anyway::DeclarationError => e
      abort e.message
    end

    out = ENV["OUT"]
    if flag.call(ENV["CHECK"])
      abort "docuconf: CHECK=1 needs OUT=FILE" unless out
      current = File.exist?(out) ? File.read(out) : nil
      abort "docuconf: #{out} is #{current ? "out of date" : "missing"}; run without CHECK=1 to regenerate it" if current != text
      warn "docuconf: #{out} is up to date"
    elsif out
      File.write(out, text)
      warn "docuconf: wrote #{out}"
    else
      $stdout.print text
    end
  end

  desc "Validate the current environment and files against every docuconf config"
  task check: :environment do
    Docuconf::Anyway::Railtie.eager_load_configs
    Docuconf::Anyway.validate_all!
    puts "docuconf: configuration is valid"
  rescue Docuconf::Anyway::ValidationError, Docuconf::Anyway::DeclarationError => e
    warn e.message
    exit 1
  end
end
