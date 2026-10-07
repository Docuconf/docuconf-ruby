# frozen_string_literal: true

# Serves config.ru with WEBrick on the configured PORT. Puma and `rackup`
# can serve config.ru as is.
require "bundler/setup"
require "rackup"

app = Rack::Builder.parse_file(File.join(__dir__, "config.ru"))
%w[INT TERM].each { |signal| trap(signal) { Rackup::Handler::WEBrick.shutdown } }
Rackup::Handler::WEBrick.run(app, Host: "0.0.0.0", Port: CONFIG.port)
