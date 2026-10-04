# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "docuconf/anyway"
require "docuconf/anyway/cli"
require_relative "support/certs"
require_relative "support/env"
require_relative "support/gateway"
require_relative "support/cue"
require_relative "fixtures/gateway_config"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.include EnvHelper
  config.include CertHelper

  config.before do
    Docuconf::Anyway.watch_files = false
    Docuconf::Anyway.export_mode = false
  end
end
