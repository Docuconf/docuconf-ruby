# frozen_string_literal: true

# The shop: one program, two roles (web and worker), configured through the
# hand-written contract in contract.json, loaded in contract-first mode. It
# has no server, database or queue: it checks its configuration, prints one
# line and exits.
#
#   DOCUCONF_ROLE=web DATABASE_URL=... ALLOWED_ORIGINS=... bundle exec ruby shop.rb
require "bundler/setup"
require "docuconf/anyway"

module Shop
  CONTRACT = Docuconf::Anyway::Contract.parse(File.read(File.join(__dir__, "contract.json")))

  # Validates env against the contract and returns the typed values by
  # name, or raises a Docuconf::Anyway::ValidationError listing every
  # problem. File inputs are read under env's DOCUCONF_FILE_ROOT when set.
  def self.load(env = ENV, termination_log: true)
    CONTRACT.load(env, termination_log: termination_log, watch: false)
  end

  # The line the shop prints once its configuration is valid, from the
  # typed values (QUEUES and ALLOWED_ORIGINS are arrays, PORT an Integer,
  # WEBHOOKS_ENABLED a boolean).
  def self.summary(config)
    case config["DOCUCONF_ROLE"]
    when "web"
      "shop web: port #{config["PORT"]}, origins #{config["ALLOWED_ORIGINS"].join(",")}"
    when "worker"
      "shop worker: queues #{config["QUEUES"].join(",")}, webhooks #{config["WEBHOOKS_ENABLED"] ? "on" : "off"}"
    end
  end

  # Loads the configuration and prints the summary. On invalid
  # configuration it prints every problem to err, writes the termination
  # log and exits 1, never printing a secret.
  def self.main(env = ENV, out: $stdout, err: $stderr)
    config = Docuconf::Anyway.exit_on_failure(err: err) { load(env, termination_log: false) }
    out.puts summary(config)
  end
end

Shop.main if $PROGRAM_NAME == __FILE__
