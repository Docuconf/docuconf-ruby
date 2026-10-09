# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
# TOML config files and overlays (optional at runtime; the specs and the
# conformance suite read TOML).
gem "tomlrb", "~> 2.0"

group :rails, optional: true do
  gem "railties", ">= 7.1"
end
