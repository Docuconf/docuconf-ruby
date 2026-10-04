# frozen_string_literal: true

require_relative "lib/docuconf/anyway/version"

Gem::Specification.new do |spec|
  spec.name = "docuconf-anyway"
  spec.version = Docuconf::Anyway::VERSION
  spec.authors = ["docuconf contributors"]
  spec.summary = "Typed configuration contracts for anyway_config: describe, validate at boot, export to CUE"
  spec.description = <<~TXT
    docuconf for Ruby. Extends anyway_config with descriptions, secrets, constraints and file inputs
    (config files, TLS key pairs, CA bundles, keystores), validates the environment and mounted files
    at boot with stable error codes, and exports the declaration as a docuconf CUE contract that the
    Kubernetes platform validates before deploying.
  TXT
  spec.homepage = "https://github.com/docuconf/docuconf-ruby"
  # Licence pending: see README.
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/releases",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.{rb,rake}", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["docuconf"]
  spec.require_paths = ["lib"]

  spec.add_dependency "anyway_config", ">= 2.6", "< 3"
end
