# frozen_string_literal: true

RSpec.describe "file inputs at boot" do
  def expect_violations(*expected)
    expect { Fixtures::GatewayConfig.new }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
      expect(codes(e)).to contain_exactly(*expected)
      yield e if block_given?
    }
  end

  it "loads every file type when all is well" do
    in_gateway do |root, pki|
      c = Fixtures::GatewayConfig.new
      expect(c.routes).to eq("routes" => [{"match" => "/api", "upstream" => "https://api.internal", "timeout" => "5s"}])
      expect(c.routes).to be_frozen
      expect(c.serving_tls).to be_a(Docuconf::Anyway::TLSMaterial)
      expect(c.serving_tls.certificate.to_der).to eq pki[:cert].to_der
      expect(c.serving_tls.ssl_context).to be_a(OpenSSL::SSL::SSLContext)
      expect(c.serving_tls.inspect).to include("key=[redacted]")
      expect(c.serving_tls.inspect).not_to include("PRIVATE KEY")
      expect(c.upstream_ca.certificates.size).to eq 1
      expect(c.partner_keystore).to be_a(OpenSSL::PKCS12)
      expect(c.partner_keystore.certificate.to_der).to eq pki[:cert].to_der
      expect(c.license).to eq "ABCDE-12345-FGHIJ-67890\n"
      expect(c.geoip).to eq File.join(root, "data/geoip/GeoLite2-City.mmdb")
      expect(c.docuconf_files.keys).to contain_exactly(:routes, :serving_tls, :upstream_ca, :partner_keystore, :license, :geoip)
    end
  end

  it "reports a missing required file and leaves optional ones nil" do
    in_gateway do |root|
      File.delete(File.join(root, "etc/gateway/license/license.key"))
      File.delete(File.join(root, "data/geoip/GeoLite2-City.mmdb"))
      expect_violations(["license", :file_missing])
    end
    in_gateway do |root|
      File.delete(File.join(root, "data/geoip/GeoLite2-City.mmdb"))
      expect(Fixtures::GatewayConfig.new.geoip).to be_nil
    end
  end

  it "reports a malformed config file" do
    in_gateway do |root|
      write_file(root, "etc/gateway/routes/routes.yaml", "routes: [unclosed\n")
      expect_violations(["routes", :file_malformed])
    end
  end

  it "reports a config file that does not match its schema" do
    in_gateway do |root|
      write_file(root, "etc/gateway/routes/routes.yaml", "routes:\n  - match: api\n    upstream: ftp://x\n    extra: 1\n")
      expect_violations(["routes", :schema_mismatch]) do |e|
        msg = e.violations.first.message
        expect(msg).to include("/routes/0/match: does not match pattern ^/")
        expect(msg).to include("/routes/0: property extra is not allowed")
      end
    end
  end

  it "accepts a byte-order mark in YAML and JSON" do
    in_gateway do |root|
      write_file(root, "etc/gateway/routes/routes.yaml", "﻿#{GatewayHelper::ROUTES}")
      expect(Fixtures::GatewayConfig.new.routes["routes"].size).to eq 1
    end
  end

  it "reads a file from its pathEnv variable, under DOCUCONF_FILE_ROOT" do
    in_gateway("ROUTES_FILE" => "/srv/alt/routes.yaml") do |root|
      write_file(root, "srv/alt/routes.yaml", "routes:\n  - match: /alt\n    upstream: http://alt\n")
      expect(Fixtures::GatewayConfig.new.routes["routes"].first["match"]).to eq "/alt"
    end
  end

  it "reports a file larger than max_size" do
    in_gateway do |root|
      write_file(root, "etc/gateway/routes/routes.yaml", GatewayHelper::ROUTES + ("#" * 70_000))
      expect_violations(["routes", :file_too_large])
    end
  end

  it "reports an unreadable file" do
    skip "root can read any file" if Process.uid.zero?

    in_gateway do |root|
      File.chmod(0o000, File.join(root, "etc/gateway/license/license.key"))
      expect_violations(["license", :file_unreadable])
    end
  end

  it "reports a permission error as file_unreadable, with the fsGroup hint" do
    in_gateway do |root|
      path = File.join(root, "etc/gateway/license/license.key")
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(path).and_raise(Errno::EACCES)
      expect_violations(["license", :file_unreadable]) do |e|
        expect(e.violations.first.message).to include("fsGroup")
      end
    end
  end

  describe "TLS" do
    it "reports a certificate that expires within min_remaining" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki(not_after: Time.now + (10 * CertHelper::DAY)))
        expect_violations(["serving-tls", :certificate_expiring])
      end
    end

    it "reports an expired certificate" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki(not_before: Time.now - (20 * CertHelper::DAY), not_after: Time.now - CertHelper::DAY))
        expect_violations(["serving-tls", :certificate_invalid]) do |e|
          expect(e.violations.first.message).to include("expired")
        end
      end
    end

    it "reports a DNS name the certificate does not cover" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki(dns: %w[gateway.internal]))
        expect_violations(["serving-tls", :certificate_name_mismatch]) do |e|
          expect(e.violations.first.message).to eq "certificate does not cover api.example.com"
        end
      end
    end

    it "accepts a wildcard for a single label" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki(dns: %w[gateway.internal *.example.com]))
        expect { Fixtures::GatewayConfig.new }.not_to raise_error
      end
    end

    it "reports a key that does not match the certificate" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki)
        write_file(root, "etc/gateway/tls/tls.key", make_key(:ec).private_to_pem)
        expect_violations(["serving-tls", :key_mismatch])
      end
    end

    it "reports a disallowed key algorithm" do
      in_gateway do |root|
        write_tls(root, "etc/gateway/tls", make_pki(leaf_alg: :ed25519))
        expect_violations(["serving-tls", :certificate_invalid]) do |e|
          expect(e.violations.first.message).to eq "key algorithm Ed25519 is not one of ECDSA, RSA"
        end
      end
    end

    it "reports a certificate that does not chain to ca.crt" do
      in_gateway do |root|
        other_ca_key = make_key(:rsa2)
        other_ca = make_cert(cn: "Other CA", key: other_ca_key, ca: true)
        write_file(root, "etc/gateway/tls/ca.crt", other_ca.to_pem)
        expect_violations(["serving-tls", :certificate_invalid]) do |e|
          expect(e.violations.first.message).to include("does not chain to ca.crt")
        end
      end
    end

    it "reports a missing ca.crt when require_ca is set, and a missing tls.key" do
      in_gateway do |root|
        File.delete(File.join(root, "etc/gateway/tls/ca.crt"))
        File.delete(File.join(root, "etc/gateway/tls/tls.key"))
        expect_violations(["serving-tls", :file_missing])
      end
    end

    it "reports garbage in tls.crt without echoing tls.key" do
      in_gateway do |root|
        write_file(root, "etc/gateway/tls/tls.crt", "not a certificate")
        write_file(root, "etc/gateway/tls/tls.key", "-----BEGIN PRIVATE KEY-----\nc2VjcmV0\n-----END PRIVATE KEY-----\n")
        # No PEM certificate at all is file_malformed; a PEM key that does not
        # parse is certificate_invalid (SPEC §11.2 item 5).
        expect_violations(["serving-tls", :file_malformed], ["serving-tls", :certificate_invalid]) do |e|
          expect(e.message).not_to include("c2VjcmV0")
        end
      end
    end

    it "accepts a chain ordered leaf first, and reports one in the wrong order" do
      in_gateway do |root|
        ca_key = make_key(:rsa)
        ca = CertHelper.cache[:ca] || make_pki[:ca]
        int_key = make_key(:ec)
        int = make_cert(cn: "Intermediate", key: int_key, issuer: ca, issuer_key: ca_key, ca: true)
        leaf_key = make_key(:ec)
        leaf = make_cert(cn: "gateway.internal", key: leaf_key, issuer: int, issuer_key: int_key,
          dns: %w[gateway.internal api.example.com])
        write_file(root, "etc/gateway/tls/tls.crt", leaf.to_pem + int.to_pem)
        write_file(root, "etc/gateway/tls/tls.key", leaf_key.private_to_pem)
        write_file(root, "etc/gateway/tls/ca.crt", ca.to_pem)
        expect { Fixtures::GatewayConfig.new }.not_to raise_error

        write_file(root, "etc/gateway/tls/tls.crt", int.to_pem + leaf.to_pem)
        expect_violations(["serving-tls", :key_mismatch], ["serving-tls", :certificate_invalid],
          ["serving-tls", :certificate_name_mismatch], ["serving-tls", :certificate_name_mismatch])
      end
    end
  end

  it "reports a CA bundle with too few certificates as file_malformed" do
    in_gateway do |root|
      write_file(root, "etc/gateway/ca/bundle.pem", "no certificates here\n")
      expect_violations(["upstream-ca", :file_malformed])
    end
  end

  it "reports a keystore that does not open with its password" do
    in_gateway("GATEWAY_KEYSTORE_PASSWORD" => "wrong") do
      expect_violations(["partner-keystore", :keystore_unreadable]) do |e|
        expect(e.message).not_to include("wrong")
      end
    end
  end

  it "reports a text file that does not match its pattern" do
    in_gateway do |root|
      write_file(root, "etc/gateway/license/license.key", "ABCDE-12345\n")
      expect_violations(["license", :pattern_mismatch])
    end
  end

  it "reports variable and file problems together" do
    in_gateway("GATEWAY_PORT" => "x", "GATEWAY_REGION" => nil) do |root|
      File.delete(File.join(root, "etc/gateway/license/license.key"))
      write_file(root, "etc/gateway/routes/routes.yaml", "{")
      write_tls(root, "etc/gateway/tls", make_pki(dns: %w[other.internal]))
      expect_violations(
        ["GATEWAY_PORT", :invalid_type], ["GATEWAY_REGION", :missing_required], ["license", :file_missing],
        ["routes", :file_malformed], ["serving-tls", :certificate_name_mismatch], ["serving-tls", :certificate_name_mismatch]
      )
    end
  end

  describe "reload: :watch" do
    it "reloads a changed input and keeps the old value when the new one is invalid" do
      in_gateway do |root|
        c = Fixtures::GatewayConfig.new
        watcher = Docuconf::Anyway::Watcher.new(c, c.class.docuconf_declaration.files.select { |f| f.reload == "watch" })
        seen = []
        c.on_file_change(:routes) { |v| seen << v }

        write_file(root, "etc/gateway/routes/routes.yaml", "routes:\n  - match: /v2\n    upstream: https://v2\n# changed\n")
        expect(watcher.poll).to eq [:routes]
        expect(c.routes["routes"].first["match"]).to eq "/v2"
        expect(seen.size).to eq 1

        expect {
          write_file(root, "etc/gateway/routes/routes.yaml", "routes: []\n# now invalid, and a different size\n")
          expect(watcher.poll).to eq []
        }.to output(/reload of routes rejected/).to_stderr
        expect(c.routes["routes"].first["match"]).to eq "/v2"

        new_pki = make_pki
        write_tls(root, "etc/gateway/tls", new_pki)
        expect(watcher.poll).to eq [:serving_tls]
        expect(c.serving_tls.certificate.to_der).to eq new_pki[:cert].to_der
      end
    end

    it "starts a background watcher after a successful load" do
      in_gateway("DOCUCONF_WATCH_INTERVAL" => "0.05") do |root|
        Docuconf::Anyway.watch_files = true
        c = Fixtures::GatewayConfig.new
        expect(c.docuconf_watcher).to be_a(Docuconf::Anyway::Watcher)
        write_file(root, "etc/gateway/routes/routes.yaml", "routes:\n  - match: /bg\n    upstream: https://bg\n")
        deadline = Time.now + 5
        sleep 0.05 until c.routes["routes"].first["match"] == "/bg" || Time.now > deadline
        expect(c.routes["routes"].first["match"]).to eq "/bg"
      ensure
        c&.docuconf_watcher&.stop
      end
    end

    it "notices a Kubernetes-style ..data symlink swap" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "etc/w")
        FileUtils.mkdir_p(File.join(dir, "..2024_01"))
        File.write(File.join(dir, "..2024_01/note.txt"), "one")
        File.symlink("..2024_01", File.join(dir, "..data"))
        File.symlink("..data/note.txt", File.join(dir, "note.txt"))
        klass = Class.new(Anyway::Config) do
          include Docuconf::Anyway
          config_name :watchme
          text_file :note, path: "/etc/w/note.txt", description: "A watched note", reload: :watch
        end
        with_env("DOCUCONF_FILE_ROOT" => root) do
          c = klass.new
          watcher = Docuconf::Anyway::Watcher.new(c, klass.docuconf_declaration.files)
          FileUtils.mkdir_p(File.join(dir, "..2024_02"))
          File.write(File.join(dir, "..2024_02/note.txt"), "two")
          File.unlink(File.join(dir, "..data"))
          File.symlink("..2024_02", File.join(dir, "..data"))
          expect(watcher.poll).to eq [:note]
          expect(c.note).to eq "two"
        end
      end
    end
  end
end
