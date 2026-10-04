# frozen_string_literal: true

# A complete, valid environment for Fixtures::GatewayConfig: variables plus
# every file input under a temporary DOCUCONF_FILE_ROOT.
module GatewayHelper
  ROUTES = <<~YAML
    routes:
      - match: /api
        upstream: https://api.internal
        timeout: 5s
  YAML

  def gateway_env(root)
    {
      "DOCUCONF_FILE_ROOT" => root,
      "DOCUCONF_TERMINATION_LOG" => File.join(root, "termination-log"),
      "GATEWAY_DATABASE_URL" => "postgres://app:s3cr3t-pw@db.internal/gateway",
      "GATEWAY_PUBLIC_URL" => "https://gateway.example.com",
      "GATEWAY_REGION" => "eu-west-1",
      "GATEWAY_ALLOWED_ORIGINS" => "https://a.example.com,https://b.example.com",
      "GATEWAY_KEYSTORE_PASSWORD" => "changeit",
      "ROUTES_FILE" => nil,
      "SSL_CERT_FILE" => nil
    }
  end

  def write_gateway_files(root, pki: make_pki)
    write_file(root, "etc/gateway/routes/routes.yaml", ROUTES)
    write_tls(root, "etc/gateway/tls", pki)
    write_file(root, "etc/gateway/ca/bundle.pem", pki[:ca].to_pem)
    p12 = OpenSSL::PKCS12.create("changeit", "partner", pki[:key], pki[:cert])
    write_file(root, "etc/gateway/partner/keystore.p12", p12.to_der)
    write_file(root, "etc/gateway/license/license.key", "ABCDE-12345-FGHIJ-67890\n")
    write_file(root, "data/geoip/GeoLite2-City.mmdb", "\x00\x01binary".b)
    pki
  end

  # Runs the block inside a valid gateway environment; `env` overrides.
  def in_gateway(env = {})
    Dir.mktmpdir("docuconf") do |root|
      pki = write_gateway_files(root)
      without_prefix("GATEWAY_") do
        with_env(gateway_env(root).merge(env)) { yield root, pki }
      end
    end
  end
end

RSpec.configure { |c| c.include GatewayHelper }
